import Foundation
import OSLog
import Shared

/// Chooses the scanner engine.
///
/// The Rust core is the production engine; the Swift core is the fallback for a
/// build without the Rust binary and the reference the Rust behaviour is tested
/// against. Both satisfy `ScannerEngine`, so nothing above this factory knows
/// which one it is talking to — which is exactly the abstraction boundary §6.4
/// asks for.
public enum ScannerEngineFactory {
    /// The engine this build should use.
    ///
    /// A Rust binary that reports a mismatched ABI version is refused rather than
    /// used, because a struct layout difference would corrupt results silently.
    public static func makeDefault(rules: RuleEngine) -> any ScannerEngine {
        #if canImport(SiftScanner)
        if RustScannerEngine.verifyContractVersion() {
            SiftLog.scan.notice("Using the Rust scanner core")
            return RustScannerEngine()
        }
        SiftLog.scan.error("Rust scanner core refused: ABI version mismatch; falling back to Swift")
        #endif
        SiftLog.scan.notice("Using the Swift scanner core")
        return SwiftScannerEngine(rules: rules)
    }

    /// True when this build links the Rust core.
    public static var hasRustCore: Bool {
        #if canImport(SiftScanner)
        return RustScannerEngine.verifyContractVersion()
        #else
        return false
        #endif
    }
}

/// A tiny lifetime helper for the C string buffers used in one call.
extension String {
    /// Runs `body` with a UTF-8 buffer whose lifetime covers the call.
    ///
    /// The C ABI carries a pointer plus a length and never keeps either, so the
    /// buffer only needs to outlive the call — which the closure guarantees.
    func withCStringBuffer<T>(_ body: (CStringBuffer) throws -> T) rethrows -> T {
        let buffer = CStringBuffer(self)
        defer { buffer.release() }
        return try body(buffer)
    }
}
