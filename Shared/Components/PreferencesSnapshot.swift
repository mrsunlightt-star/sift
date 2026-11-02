import Foundation

/// A value snapshot of the preferences the confirmation panel reads.
///
/// The settings store is an actor, so reading it inside a view body would be an
/// async call per render. The shell publishes this snapshot instead, which also
/// keeps the confirmation panel a pure function of its inputs.
public final class PreferencesSnapshot: ObservableObject {
    @Published public var skipConfirmation: Bool
    @Published public var requireConfirmation: Bool
    /// Whether this Mac has ever finished a cleanup.
    ///
    /// The confirmation panel says so on the first one and never again: a hint
    /// that repeats is nagging, and a hint that never appears leaves the first
    /// batch — the one a user has no basis to judge — unexplained.
    @Published public var hasCompletedCleanup: Bool

    public init(
        skipConfirmation: Bool = false,
        requireConfirmation: Bool = true,
        hasCompletedCleanup: Bool = false
    ) {
        self.skipConfirmation = skipConfirmation
        self.requireConfirmation = requireConfirmation
        self.hasCompletedCleanup = hasCompletedCleanup
    }
}
