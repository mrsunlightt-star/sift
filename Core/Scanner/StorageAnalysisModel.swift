import Foundation
import Shared

/// Why a storage run ended without a result.
///
/// A failed measurement is not an empty disk. Keeping the reason lets the page
/// say what happened and offer a retry instead of presenting a zeroed result as
/// a finished analysis.
public struct StorageAnalysisFailure: Sendable, Equatable {
    public let code: ErrorCode
    public let message: String

    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// How the last storage run ended.
public enum StorageAnalysisRunOutcome: Sendable, Equatable {
    /// The measurement finished. `partial` says it skipped unreadable folders
    /// or hit its budget, so the totals are a lower bound.
    case completed(partial: Bool)
    case failed(StorageAnalysisFailure)
    /// The user stopped the run. Not a failure and not a result.
    case cancelled
}

/// The storage page's session state.
///
/// It lives in `AppEnvironment` rather than in the view so that leaving the page
/// keeps the last result: returning to Storage shows what was measured, and an
/// analysis starts only when the user asks for one.
@MainActor
public final class StorageAnalysisModel: ObservableObject {
    @Published public private(set) var analysis: StorageAnalysis = .empty
    @Published public private(set) var report: StorageDiagnosticReport = .empty
    @Published public private(set) var isAnalyzing = false
    @Published public private(set) var lastAnalyzedAt: Date?
    /// How the last run ended. A failure leaves the previous analysis and its
    /// timestamp in place: the page shows the last good result and says the new
    /// run did not produce one.
    @Published public private(set) var runOutcome: StorageAnalysisRunOutcome?
    /// Whether the next run also asks the diagnostic providers about the whole
    /// volume. File categories always cover the home folder's volume; this is
    /// the slower, read-only half of the page.
    @Published public var includeVolumeRoot = false

    private var cancellation = CancellationFlag()

    public init() {}

    public var hasResult: Bool {
        report.providerCount > 0 || analysis.scannedFileCount > 0 || analysis.totalBytes > 0
    }

    /// Starts a run unless one is already in flight.
    ///
    /// The returned flag is what the walker polls; `nil` means this request was
    /// refused instead of starting a second analysis over the first one.
    func begin() -> CancellationFlag? {
        guard !isAnalyzing else { return nil }
        cancellation.isCancelled = false
        isAnalyzing = true
        runOutcome = nil
        return cancellation
    }

    func finish(analysis: StorageAnalysis, report: StorageDiagnosticReport) {
        self.analysis = analysis
        self.report = report
        lastAnalyzedAt = Date()
        // A capped *list* is not an incomplete measurement. The verdict only
        // says partial when the walk could not read a folder or a diagnostic
        // provider reported incomplete coverage.
        runOutcome = .completed(
            partial: analysis.skippedCount > 0 || report.coverage != .complete
        )
        isAnalyzing = false
    }

    /// Records a run that could not measure anything.
    ///
    /// The last successful analysis stays on screen and keeps its timestamp;
    /// only `runOutcome` changes. Replacing it with `.empty` would be
    /// indistinguishable from a disk that genuinely held nothing.
    func recordFailure(_ failure: StorageAnalysisFailure) {
        runOutcome = .failed(failure)
        isAnalyzing = false
    }

    /// Records a run the user stopped. Keeps the previous result as it was.
    func recordCancellation() {
        runOutcome = .cancelled
        isAnalyzing = false
    }

    /// Clears the running mark when a run ended without a result (cancelled or
    /// refused). A completed run has already cleared it.
    func abortIfStillRunning() {
        if isAnalyzing {
            isAnalyzing = false
        }
    }

    public func cancel() {
        cancellation.isCancelled = true
    }
}
