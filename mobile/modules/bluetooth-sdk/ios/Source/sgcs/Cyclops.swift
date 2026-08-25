//
//  Cyclops.swift
//  OpenWearableAI Cyclops driver — a thin subclass of MentraNexSGC.
//
//  Cyclops firmware implements the MentraOS OEM firmware spec (GATT service
//  4860, protobuf control, LC3 mic on 0xA0) — the exact protocol MentraNexSGC
//  already speaks. The deltas, per the ADR-0008 distribution-ladder decision:
//    1. Scan filter: advertised name "OpenWearableAI" (no Nex1-/MENTRA_ prefix)
//    2. Device type: DeviceTypes.CYCLOPS (displayless, camera+mic — the
//       capability tables carry the truth; DeviceInfo self-report is logged
//       only, same as upstream)
//    3. Photo channel: OWAI L2CAP CoC stream (PSM published in GATT char
//       F00D0005; stream format ['OWAI'][total][crc32][w][h][JPEG]) — the
//       spec has no camera chapter yet, so photos ride our own channel
//       (hybrid decision, owner 2026-08-06). Reader ported from the proven
//       Viewfinder CocPhotoReader (phone/CyclopsViewfinder in the
//       OpenWearableAI repo).
//
//  All display-path behavior is inherited and harmless: the firmware answers
//  unknown/unsupported commands per the spec's forward-compatibility rule.
//

import CoreBluetooth
import Foundation
import ImageIO
import Photos

class CyclopsSGC: MentraNexSGC {
    // MARK: - Singleton (parallel to MentraNexSGC.getInstance())

    static var cyclopsInstance: CyclopsSGC?

    @objc static func getCyclopsInstance() -> CyclopsSGC {
        if let existing = cyclopsInstance {
            return existing
        }
        let created = CyclopsSGC()
        cyclopsInstance = created
        return created
    }

    override init() {
        super.init()
        type = DeviceTypes.CYCLOPS
        Bridge.log("CYCLOPS: driver initialized (subclass of MentraNexSGC)")
    }

    // MARK: - Scan filter deltas

    override var compatibleNamePrefixes: [String] {
        ["OpenWearableAI"]
    }

    override var deviceIdPatterns: [String] {
        // Devkit advertises a fixed name; treat the whole name as the ID.
        ["(OpenWearableAI)"]
    }

    // MARK: - OWAI photo channel (L2CAP CoC)

    private let OWAI_SERVICE_UUID = CBUUID(string: "F00D0001-1C77-429A-D14C-1E0F62518C9E")
    private let OWAI_PSM_CHAR_UUID = CBUUID(string: "F00D0005-1C77-429A-D14C-1E0F62518C9E")

    private var photoChannel: CBL2CAPChannel?
    private var photoReader: CyclopsCocPhotoReader?
    private var photoChannelOpening = false

    /* CoreBluetooth delegate methods are @objc protocol members, so these
     * overrides dispatch correctly even if the parent implements them in an
     * extension. Every override calls super first — the Nex protocol path
     * (4860 discovery, protobuf, mic) is untouched. */

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        super.centralManager(central, didConnect: peripheral)
        // Additional discovery for the OWAI service (photo PSM lives there).
        peripheral.discoverServices([OWAI_SERVICE_UUID])
    }

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        super.peripheral(peripheral, didDiscoverServices: error)
        if let svc = peripheral.services?.first(where: { $0.uuid == OWAI_SERVICE_UUID }) {
            peripheral.discoverCharacteristics([OWAI_PSM_CHAR_UUID], for: svc)
        }
    }

    override func peripheral(_ peripheral: CBPeripheral,
                             didDiscoverCharacteristicsFor service: CBService,
                             error: Error?) {
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
        if service.uuid == OWAI_SERVICE_UUID,
           let psmChar = service.characteristics?.first(where: { $0.uuid == OWAI_PSM_CHAR_UUID }) {
            peripheral.readValue(for: psmChar)
        }
    }

    override func peripheral(_ peripheral: CBPeripheral,
                             didUpdateValueFor characteristic: CBCharacteristic,
                             error: Error?) {
        if characteristic.uuid == OWAI_PSM_CHAR_UUID {
            if let data = characteristic.value, data.count >= 2 {
                let psm = CBL2CAPPSM(UInt16(data[data.startIndex])
                    | UInt16(data[data.startIndex + 1]) << 8)
                if psm != 0 {
                    // Discovery and subscription re-run on every reconnect, so
                    // this read can fire more than once per link. Racing two
                    // openL2CAPChannel calls tears down the winner (observed
                    // 2026-08-25: CoC OPEN then closed 54 ms later).
                    if photoChannelOpening || photoChannel != nil {
                        Bridge.log("CYCLOPS: photo CoC PSM \(psm) — channel already open/opening, skipping")
                    } else {
                        photoChannelOpening = true
                        Bridge.log("CYCLOPS: photo CoC PSM \(psm) — opening channel")
                        peripheral.openL2CAPChannel(psm)
                    }
                }
            }
            return
        }
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
    }

    /* MentraNexSGC (display device, no L2CAP) does not implement didOpen —
     * no override keyword. If upstream ever adds one, the compiler will say
     * so on the Mac and this becomes an override calling super. */
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        photoChannelOpening = false
        guard let channel else {
            Bridge.log("CYCLOPS: CoC open failed: \(error?.localizedDescription ?? "?")")
            return
        }
        // A previous reader (stale connection) must be torn down explicitly —
        // silently replacing it left its streams scheduled with a delegate
        // about to deallocate.
        photoReader?.detach()
        photoChannel = channel
        let reader = CyclopsCocPhotoReader { [weak self] jpeg, width, height in
            self?.handlePhoto(jpeg: jpeg, width: width, height: height)
        }
        photoReader = reader
        reader.attach(channel: channel)
        Bridge.log("CYCLOPS: photo CoC channel open (mtu in \(channel.inputStream != nil ? "ok" : "?"))")
    }

    private func handlePhoto(jpeg: Data, width: UInt16, height: UInt16) {
        Bridge.log("CYCLOPS: 📸 photo received: \(jpeg.count) B (\(width)x\(height))")
        /* Orientation is corrected HERE, at the point frames enter the driver,
         * so every consumer (camera roll today; gallery index and miniapp
         * delivery later) inherits it. Sensor-side correction is closed:
         * bsp_camera_set_orientation() -> ESP_ERR_NOT_SUPPORTED (2026-08-21).
         * .downMirrored (EXIF 4, pure vertical flip) per the 08-05
         * scene-verified finding and the Viewfinder's identical correction. */
        let corrected = reoriented(jpeg, .downMirrored)
        lastPhoto = corrected
        deliverPhoto(corrected, width: width, height: height)
    }

    /* Local-first delivery (owner decision 2026-08-20): no cloud, no sync step.
     * Two destinations, in one pass:
     *   1. the app's own gallery store (Documents/MentraPhotos) plus a
     *      `cyclops_photo_saved` event so JS can index it — that is what makes
     *      the frame show up in the in-app Gallery;
     *   2. the iOS photo library, as before.
     * The camera-roll asset id travels with the event and is persisted as the
     * row's assetReceipt, so cameraRollExportCoordinator sees the frame as
     * already exported and does not save a second copy. */
    private func deliverPhoto(_ jpeg: Data, width: UInt16, height: UInt16) {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let name = "CYCLOPS_\(timestamp).jpg"
        let filePath = writeToGalleryStore(jpeg, name: name)

        saveToPhotoLibrary(jpeg) { assetIdentifier in
            guard let filePath else { return }
            Bridge.sendTypedMessage("cyclops_photo_saved", body: [
                "name": name,
                "filePath": filePath,
                "size": jpeg.count,
                "modified": timestamp,
                "width": Int(width),
                "height": Int(height),
                "assetIdentifier": assetIdentifier as Any,
            ])
        }
    }

    /// Writes the frame into the same directory the gallery's WiFi-sync path
    /// uses (`Documents/MentraPhotos`), which is also the only location
    /// localStorageService can persist as a portable relative path.
    /// Returns the absolute path, or nil if the write failed.
    private func writeToGalleryStore(_ jpeg: Data, name: String) -> String? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Bridge.log("CYCLOPS: ❌ no Documents directory — gallery copy skipped")
            return nil
        }
        let dir = docs.appendingPathComponent("MentraPhotos", isDirectory: true)
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let url = dir.appendingPathComponent(name)
            try jpeg.write(to: url, options: .atomic)
            return url.path
        } catch {
            Bridge.log("CYCLOPS: ❌ gallery copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns `jpeg` carrying the given EXIF orientation.
    ///
    /// The sensor emits JPEGs with **no EXIF block at all**, which rules out
    /// `CGImageDestinationCopyImageSource`: it *merges* metadata, so with
    /// nothing to merge into it silently writes no tag (measured 2026-08-23 —
    /// bytes preserved, orientation still nil, photos upside down).
    /// `AddImageFromSource` does write the tag, but only by decoding and
    /// re-encoding: ~46% inflation and a needless recompression of
    /// already-lossy data.
    ///
    /// So splice in a minimal APP1/Exif segment ourselves: 36 bytes holding a
    /// single Orientation tag, inserted after SOI (and after JFIF/APP0 if
    /// present). The compressed scan data is copied verbatim — verified
    /// byte-identical. Falls back to the ImageIO re-encode if the frame already
    /// carries EXIF, and to the untouched frame if even that fails: never lose
    /// a photo over a metadata edit.
    private func reoriented(_ jpeg: Data, _ orientation: CGImagePropertyOrientation) -> Data {
        if let spliced = injectingExifOrientation(jpeg, orientation.rawValue) {
            return spliced
        }
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let uti = CGImageSourceGetType(src) else { return jpeg }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, uti, 1, nil) else { return jpeg }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImagePropertyOrientation] = orientation.rawValue
        CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return jpeg }
        return out as Data
    }

    /// Builds an APP1/Exif segment carrying only the Orientation tag.
    private func exifOrientationSegment(_ orientation: UInt32) -> Data {
        let value = UInt16(truncatingIfNeeded: orientation)
        var tiff = Data()
        tiff.append(contentsOf: [0x49, 0x49])              // "II" — little-endian
        tiff.append(contentsOf: [0x2A, 0x00])              // magic 42
        tiff.append(contentsOf: [0x08, 0x00, 0x00, 0x00])  // IFD0 at offset 8
        tiff.append(contentsOf: [0x01, 0x00])              // one entry
        tiff.append(contentsOf: [0x12, 0x01])              // tag 0x0112 Orientation
        tiff.append(contentsOf: [0x03, 0x00])              // type SHORT
        tiff.append(contentsOf: [0x01, 0x00, 0x00, 0x00])  // count 1
        tiff.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8), 0x00, 0x00])
        tiff.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // no next IFD
        var payload = Data("Exif".utf8)
        payload.append(contentsOf: [0x00, 0x00])
        payload.append(tiff)
        let length = payload.count + 2
        var segment = Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
        segment.append(payload)
        return segment
    }

    /// Splices the orientation segment in after SOI. Returns nil when the frame
    /// already has an APP1 block or is not a JPEG we recognise.
    private func injectingExifOrientation(_ jpeg: Data, _ orientation: UInt32) -> Data? {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 3 < bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            if marker == 0xE1 { return nil }                  // already has EXIF
            if marker == 0xDA || marker == 0xD9 { break }     // scan / end
            let segmentLength = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if segmentLength < 2 { return nil }
            if marker == 0xE0 {                               // keep JFIF ahead of us
                index += 2 + segmentLength
                continue
            }
            break
        }
        var out = jpeg.prefix(index)
        out.append(exifOrientationSegment(orientation))
        out.append(jpeg.suffix(from: index))
        return out
    }

    private func saveToPhotoLibrary(_ jpeg: Data, completion: @escaping (String?) -> Void) {
        let save = {
            var placeholderId: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpeg, options: nil)
                placeholderId = request.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                if success {
                    Bridge.log("CYCLOPS: 📸 saved to camera roll (\(jpeg.count) B)")
                    completion(placeholderId)
                } else {
                    Bridge.log("CYCLOPS: ❌ camera-roll save failed: \(error?.localizedDescription ?? "?")")
                    completion(nil)
                }
            }
        }
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            save()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    save()
                } else {
                    Bridge.log("CYCLOPS: ❌ photo-library add permission denied — gallery copy kept")
                    completion(nil)
                }
            }
        default:
            Bridge.log("CYCLOPS: ❌ photo-library access denied — gallery copy kept")
            completion(nil)
        }
    }

    /// Most recent photo delivered over the CoC channel (debug surface until
    /// the photo-request flow is wired).
    private(set) var lastPhoto: Data?

    override func cleanup() {
        photoChannelOpening = false
        photoReader?.detach()
        photoReader = nil
        photoChannel = nil
        super.cleanup()
    }
}

// MARK: - CoC stream reader (ported from Viewfinder CocPhotoReader.swift)

/// Parses the OWAI photo stream: ['OWAI' u32][total u32][crc32 u32][w u16]
/// [h u16][JPEG bytes...], all little-endian. CoC is ordered and lossless;
/// the CRC guards firmware-side truncation only.
final class CyclopsCocPhotoReader: NSObject, StreamDelegate {
    private static let headerLen = 16
    private static let magic: UInt32 = 0x4941_574F // 'OWAI' LE

    private let onPhoto: (Data, UInt16, UInt16) -> Void
    private var channel: CBL2CAPChannel?
    private var buf = Data()

    init(onPhoto: @escaping (Data, UInt16, UInt16) -> Void) {
        self.onPhoto = onPhoto
    }

    /* The stream must NOT live on the main RunLoop: when iOS backgrounds the
     * app the main loop parks, the stream stops being serviced, flow-control
     * credits dry up and the channel collapses — photos pressed while the app
     * was off-screen died here (2026-08-25). A dedicated thread keeps
     * servicing L2CAP data during background BLE wakes, which the app's
     * bluetooth-central mode entitles it to. */
    private var streamThread: Thread?

    func attach(channel: CBL2CAPChannel) {
        self.channel = channel
        guard let input = channel.inputStream else { return }
        input.delegate = self
        let thread = Thread { [weak self] in
            input.schedule(in: .current, forMode: .default)
            input.open()
            channel.outputStream?.open()
            while let self, self.channel != nil, !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
            }
        }
        thread.name = "CyclopsCoCStream"
        thread.qualityOfService = .userInitiated
        streamThread = thread
        thread.start()
    }

    func detach() {
        let closing = channel
        channel = nil // ends the stream thread's loop
        streamThread?.cancel()
        streamThread = nil
        if let input = closing?.inputStream {
            input.delegate = nil
            input.close()
        }
        closing?.outputStream?.close()
        buf.removeAll()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            var chunk = [UInt8](repeating: 0, count: 8192)
            while input.hasBytesAvailable {
                let n = input.read(&chunk, maxLength: chunk.count)
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0 ..< n])
            }
            drain()
        case .errorOccurred:
            Bridge.log("CYCLOPS: photo stream error: \(aStream.streamError?.localizedDescription ?? "?")")
        case .endEncountered:
            Bridge.log("CYCLOPS: photo stream closed by peer")
        default:
            break
        }
    }

    private func le32(_ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in (0 ..< 4).reversed() {
            v = v << 8 | UInt32(buf[buf.startIndex + offset + i])
        }
        return v
    }

    private func le16(_ offset: Int) -> UInt16 {
        UInt16(buf[buf.startIndex + offset]) | UInt16(buf[buf.startIndex + offset + 1]) << 8
    }

    private func drain() {
        while buf.count >= Self.headerLen {
            guard le32(0) == Self.magic else {
                Bridge.log("CYCLOPS: bad photo stream magic — resyncing")
                buf.removeAll()
                return
            }
            let total = Int(le32(4))
            let want = Self.headerLen + total
            guard buf.count >= want else { return }
            let crc = le32(8)
            let width = le16(12)
            let height = le16(14)
            let jpeg = buf.subdata(in: (buf.startIndex + Self.headerLen) ..< (buf.startIndex + want))
            buf.removeSubrange(buf.startIndex ..< (buf.startIndex + want))
            if crc32(jpeg) == crc {
                onPhoto(jpeg, width, height)
            } else {
                Bridge.log("CYCLOPS: photo CRC mismatch — frame dropped")
            }
        }
    }

    /// zlib-compatible CRC32 (matches esp_rom_crc32_le on the board).
    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
