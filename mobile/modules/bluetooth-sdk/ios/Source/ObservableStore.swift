//
//  ObservableStore.swift
//  BluetoothSdk
//
//  Observable state management with immediate event emission
//

import Foundation

@MainActor
class ObservableStore {
    /* The @MainActor annotation does not hold at runtime: CoreBluetooth-queue
     * callers invoke these methods without await (Swift 5 mode), so `values`
     * is touched from multiple threads. The 2026-08-20 Cyclops pairing crash
     * (EXC_BAD_ACCESS iterating `values` in getCategory during a discovery
     * write burst) is that race. Real synchronization via NSLock; emits stay
     * outside the critical section so a listener re-entering the store cannot
     * deadlock. */
    private let stateLock = NSLock()
    private var values: [String: Any] = [:]
    private var onEmit: ((String, [String: Any]) -> Void)?
    private var listeners: [String: (String, [String: Any]) -> Void] = [:]

    nonisolated static let bluetoothCategory = "bluetooth"
    private nonisolated static let legacyCoreCategory = "core"

    nonisolated static func normalizeCategory(_ category: String) -> String {
        category == legacyCoreCategory ? bluetoothCategory : category
    }

    func configure(onEmit: @escaping (String, [String: Any]) -> Void) {
        self.onEmit = onEmit
    }

    func addListener(_ listener: @escaping (String, [String: Any]) -> Void) -> String {
        let id = UUID().uuidString
        stateLock.lock()
        listeners[id] = listener
        stateLock.unlock()
        return id
    }

    func removeListener(_ id: String) {
        stateLock.lock()
        listeners.removeValue(forKey: id)
        stateLock.unlock()
    }

    func set(_ category: String, _ key: String, _ value: Any) {
        let normalizedCategory = Self.normalizeCategory(category)
        let fullKey = "\(normalizedCategory).\(key)"

        stateLock.lock()
        let oldValue = values[fullKey]
        // Skip if unchanged
        if let old = oldValue, areEqual(old, value) {
            stateLock.unlock()
            return
        }
        values[fullKey] = value
        let listenersCopy = Array(listeners.values)
        stateLock.unlock()

        // Emit outside the lock
        let changes = [key: value]
        onEmit?(normalizedCategory, changes)
        for listener in listenersCopy {
            listener(normalizedCategory, changes)
        }
    }

    func remove(_ category: String, _ key: String) {
        let normalizedCategory = Self.normalizeCategory(category)
        let fullKey = "\(normalizedCategory).\(key)"
        stateLock.lock()
        guard values[fullKey] != nil else {
            stateLock.unlock()
            return
        }
        values.removeValue(forKey: fullKey)
        let listenersCopy = Array(listeners.values)
        stateLock.unlock()
        // Emit updated category snapshot so UI listeners clear the removed key
        let snapshot = getCategory(normalizedCategory)
        onEmit?(normalizedCategory, snapshot)
        for listener in listenersCopy { listener(normalizedCategory, snapshot) }
    }

    func get(_ category: String, _ key: String) -> Any? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return values["\(Self.normalizeCategory(category)).\(key)"]
    }

    func wouldSkipSet(_ category: String, _ key: String, _ value: Any) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let fullKey = "\(Self.normalizeCategory(category)).\(key)"
        guard let oldValue = values[fullKey] else { return false }
        return areEqual(oldValue, value)
    }

    func getCategory(_ category: String) -> [String: Any] {
        stateLock.lock()
        defer { stateLock.unlock() }
        var result: [String: Any] = [:]
        let prefix = "\(Self.normalizeCategory(category))."
        for (key, value) in values where key.hasPrefix(prefix) {
            let shortKey = String(key.dropFirst(prefix.count))
            result[shortKey] = value
        }
        return result
    }

    /// Helper to compare values
    private func areEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let l = lhs as? String, let r = rhs as? String { return l == r }
        if let l = lhs as? Int, let r = rhs as? Int { return l == r }
        if let l = lhs as? Bool, let r = rhs as? Bool { return l == r }
        if let l = lhs as? Double, let r = rhs as? Double { return l == r }
        if let l = lhs as? [String], let r = rhs as? [String] { return l == r }
        if let l = lhs as? [[String: Any]], let r = rhs as? [[String: Any]] {
            return toJson(l) == toJson(r)
        }
        return false
    }

    private func toJson(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
