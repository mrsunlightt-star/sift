import Foundation

/// A value snapshot of the preferences the confirmation panel reads.
///
/// The settings store is an actor, so reading it inside a view body would be an
/// async call per render. The shell publishes this snapshot instead, which also
/// keeps the confirmation panel a pure function of its inputs.
public final class PreferencesSnapshot: ObservableObject {
    @Published public var skipConfirmation: Bool
    @Published public var requireConfirmation: Bool

    public init(skipConfirmation: Bool = false, requireConfirmation: Bool = true) {
        self.skipConfirmation = skipConfirmation
        self.requireConfirmation = requireConfirmation
    }
}
