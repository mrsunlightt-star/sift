import Foundation
import Shared

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
    /// Whether the next run also measures the volume root. The user chooses the
    /// scope before starting; it is part of the confirmation, not a default.
    @Published public var includeVolumeRoot = false

    private var cancellation = CancellationFlag()

    public init() {}

    public var hasResult: Bool { report.providerCount > 0 }

    /// Starts a run unless one is already in flight.
    ///
    /// The returned flag is what the walker polls; `nil` means this request was
    /// refused instead of starting a second analysis over the first one.
    func begin() -> CancellationFlag? {
        guard !isAnalyzing else { return nil }
        cancellation.isCancelled = false
        isAnalyzing = true
        return cancellation
    }

    func finish(analysis: StorageAnalysis, report: StorageDiagnosticReport) {
        self.analysis = analysis
        self.report = report
        lastAnalyzedAt = Date()
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
