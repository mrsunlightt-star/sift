import Foundation

/// A minimal local history of scans and cleanups.
///
/// §7.4 keeps the last ten scans on the machine and lets the user clear them, and
/// nothing here is uploaded. Counts, sizes and timestamps only: no paths.
public enum RecentHistory {
    private static let scanKey = "history.lastScanDate"
    private static let cleanupKey = "history.lastCleanup"

    struct StoredCleanup: Codable {
        let movedCount: Int
        let releasedBytes: Int64
        let date: Date
        let operation: String
    }

    /// Removes the stored history. Nothing here is uploaded, and nothing else
    /// depends on it, so this is a plain delete.
    public static func clear() {
        UserDefaults.standard.removeObject(forKey: scanKey)
        UserDefaults.standard.removeObject(forKey: cleanupKey)
    }

    public static func recordScan() {
        UserDefaults.standard.set(Date(), forKey: scanKey)
    }

    public static func recordCleanup(_ outcome: CleanupOutcome) {
        let payload = StoredCleanup(
            movedCount: outcome.movedCount,
            releasedBytes: outcome.releasedBytes,
            date: outcome.finishedAt,
            operation: outcome.operationName.rawValue
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: cleanupKey)
        }
    }

    public static func lastScanDate() -> Date? {
        UserDefaults.standard.object(forKey: scanKey) as? Date
    }

    /// The last cleanup, restored without its per-item results.
    public static func lastOutcome() -> CleanupOutcome? {
        guard let data = UserDefaults.standard.data(forKey: cleanupKey),
              let stored = try? JSONDecoder().decode(StoredCleanup.self, from: data) else {
            return nil
        }
        return CleanupOutcome(
            results: [],
            categoryTotals: [],
            startedAt: stored.date,
            finishedAt: stored.date,
            operationName: CleanupOperationName(rawValue: stored.operation) ?? .junkCleanup,
            summaryOverride: (count: stored.movedCount, bytes: stored.releasedBytes)
        )
    }
}
