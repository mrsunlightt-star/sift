import Foundation

#if canImport(SiftScanner)
import SiftScanner

/// A UTF-8 buffer handed to the C ABI.
///
/// The ABI carries a pointer plus a length and never retains either, so the
/// buffer only needs to outlive the call. `String.withCStringBuffer` expresses
/// that scope, which is what keeps the FFI boundary from leaking a buffer or
/// reading freed memory.
struct CStringBuffer {
    private let storage: UnsafeMutablePointer<UInt8>
    private let byteCount: Int

    init(_ value: String) {
        var bytes = Array(value.utf8)
        // The ABI carries a length, so a terminator is not required; it costs one
        // byte and keeps the data usable by anything expecting C strings.
        bytes.append(0)
        storage = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        storage.initialize(from: bytes, count: bytes.count)
        byteCount = bytes.count - 1
    }

    /// The value the C function expects.
    ///
    /// The field is a mutable pointer because that is what the typedef declares;
    /// the callee only reads it.
    var value: SiftString {
        SiftString(ptr: storage, len: byteCount)
    }

    func release() {
        storage.deinitialize(count: byteCount + 1)
        storage.deallocate()
    }
}

/// Runs `body` with a buffer for an optional string, or with the ABI's null
/// value when it is absent.
///
/// An empty C string is not "no value": the Rust side treats an empty category
/// as a category named "", so absence has to be a null pointer.
func withOptionalCStringBuffer<T>(
    _ value: String?,
    _ body: (SiftString) throws -> T
) rethrows -> T {
    guard let value else { return try body(SiftString(ptr: nil, len: 0)) }
    return try value.withCStringBuffer { buffer in try body(buffer.value) }
}

/// Reads a string out of the C typedef.
///
/// The imported C type cannot be extended in place, so the conversion is a free
/// function rather than a property.
func readString(_ value: SiftString) -> String {
    guard let pointer = value.ptr, value.len > 0 else { return "" }
    let buffer = UnsafeBufferPointer(start: pointer, count: value.len)
    return String(decoding: buffer, as: UTF8.self)
}

/// Proves the C typedef and the layout the Swift side assumes agree.
///
/// If the header changes shape, this fails on the Rust-FFI build — the only
/// build where both languages are present to disagree.
enum SiftABILayout {
    static func verify() {
        // `SiftString` is a pointer followed by a byte count.
        assert(
            MemoryLayout<SiftString>.size
                == MemoryLayout<UnsafeMutableRawPointer?>.size + MemoryLayout<Int>.size
        )
        assert(SIFT_FFI_VERSION == 1, "the app and the header must agree on the ABI version")
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

#endif
