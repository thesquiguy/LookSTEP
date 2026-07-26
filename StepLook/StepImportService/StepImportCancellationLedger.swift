import Foundation

nonisolated struct StepImportCancellationLedger {
    static let maximumCount = 64
    static let retentionSeconds: TimeInterval = 5

    private var expirations: [String: TimeInterval] = [:]

    var count: Int { expirations.count }

    mutating func record(_ identifier: String, now: TimeInterval) {
        removeExpired(now: now)
        if expirations[identifier] == nil,
           expirations.count >= Self.maximumCount,
           let eviction = expirations.min(by: {
               if $0.value == $1.value { return $0.key < $1.key }
               return $0.value < $1.value
           }) {
            expirations.removeValue(forKey: eviction.key)
        }
        expirations[identifier] = now + Self.retentionSeconds
    }

    mutating func consume(_ identifier: String, now: TimeInterval) -> Bool {
        removeExpired(now: now)
        return expirations.removeValue(forKey: identifier) != nil
    }

    func contains(_ identifier: String) -> Bool {
        expirations[identifier] != nil
    }

    mutating func removeExpired(now: TimeInterval) {
        expirations = expirations.filter { $0.value > now }
    }
}
