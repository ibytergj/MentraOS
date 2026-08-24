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
                    Bridge.log("CYCLOPS: photo CoC PSM \(psm) — opening channel")
                    peripheral.openL2CAPChannel(psm)
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
        guard let channel else {
            Bridge.log("CYCLOPS: CoC open failed: \(error?.localizedDescription ?? "?")")
            return
        }
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

    /// Returns `jpeg` with its EXIF orientation tag set, rewriting metadata only.
    ///
    /// `CGImageDestinationCopyImageSource` copies the compressed scan data
    /// verbatim; `AddImageFromSource` (used first) decodes and re-encodes,
    /// which inflated frames ~46% (166 KB → 243 KB, measured 2026-08-23) and
    /// re-compressed already-lossy JPEG for nothing. Falls back to the input
    /// unchanged if anything fails: never lose the frame over a metadata edit.
    private func reoriented(_ jpeg: Data, _ orientation: CGImagePropertyOrientation) -> Data {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let uti = CGImageSourceGetType(src) else { return jpeg }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, uti, 1, nil) else { return jpeg }
        let props: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue]
        guard CGImageDestinationCopyImageSource(dst, src, props as CFDictionary, nil) else { return jpeg }
        return out as Data
    }

    /// Saves to the iOS photo library. `completion` always runs — with the new
    /// asset's local identifier on success, nil otherwise — so the gallery row
    /// is still indexed when the library is unavailable or permission is denied.
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

    func attach(channel: CBL2CAPChannel) {
        self.channel = channel
        guard let input = channel.inputStream else { return }
        input.delegate = self
        input.schedule(in: .main, forMode: .default)
        input.open()
        channel.outputStream?.open()
    }

    func detach() {
        if let input = channel?.inputStream {
            input.close()
            input.remove(from: .main, forMode: .default)
            input.delegate = nil
        }
        channel?.outputStream?.close()
        channel = nil
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
