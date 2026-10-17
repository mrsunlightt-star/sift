// swift-tools-version: 6.0
import Foundation
import PackageDescription

// MARK: - Rust scanner core

/// Root of the checkout, used to point the compiler and linker at the Rust
/// archive.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let bridgeDirectory = packageRoot.appendingPathComponent("Bridge").path

/// The Rust scanner core is a build input, not an optional extra: the
/// specification makes it the production scanning engine (§6.1). One bootstrap
/// step produces the archive at a fixed path, and both build systems use it from
/// there:
///
///     Scripts/bootstrap.sh          # builds it for this machine
///
/// A fixed path is deliberate. SwiftPM evaluates manifests inside a sandbox where
/// a `fileExists` probe can answer "no" for a file that is present, so the
/// manifest does not try to discover the library. This is the path
/// `Scripts/build-rust-core.sh` writes.
let rustLibrary = packageRoot.appendingPathComponent("Bridge/macos-universal/libsift_ffi.a").path

/// Makes the C module visible to the Swift Clang importer. Every target needs it,
/// not only the one that imports the module: a target's `.swiftmodule` records its
/// imports, and clients must be able to resolve them.
let runtimeSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-I\(bridgeDirectory)"])
]

/// Linker flags that pull the archive into an executable or test bundle.
let runtimeLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-force_load", "-Xlinker", rustLibrary]),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("Security"),
    .linkedLibrary("c++"),
]

// MARK: - Package

let package = Package(
    name: "Sift",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Sift", targets: ["SiftApp"]),
        // A runnable verification suite that needs only SwiftPM, so the
        // safety-critical behaviour can be checked on a machine without Xcode.
        .executable(name: "SiftSelfTest", targets: ["SiftSelfTest"]),
    ],
    targets: [
        // Design system, shared components and the string catalog.
        .target(
            name: "Shared",
            path: "Shared",
            resources: [
                // The catalog is the source of record and what Xcode compiles.
                .process("Localization/Localizable.xcstrings"),
                // The same table rendered as `.lproj` bundles, so a build without
                // Xcode (no `xcstringstool`) still ships localised text instead of
                // raw keys. Both outputs come from `Scripts/generate-strings.py`.
                .process("Localization/Compiled"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),

        // Domain models, rules, permissions, file operations, reports,
        // entitlements, logging and the scanning engines.
        .target(
            name: "Core",
            dependencies: ["Shared"],
            path: "Core",
            resources: [.process("Resources/CleaningRules.json")],
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),

        // Feature view models and views. Split by feature so a change to the
        // uninstaller cannot break the storage analysis build.
        .target(
            name: "FeatureDashboard",
            dependencies: ["Core", "Shared"],
            path: "Features/Dashboard",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),
        .target(
            name: "FeatureScan",
            dependencies: ["Core", "Shared"],
            path: "Features/Scan",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),
        .target(
            name: "FeatureJunkCleanup",
            dependencies: ["Core", "Shared"],
            path: "Features/JunkCleanup",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),
        .target(
            name: "FeatureUninstaller",
            dependencies: ["Core", "Shared"],
            path: "Features/Uninstaller",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),
        .target(
            name: "FeatureStorageAnalysis",
            dependencies: ["Core", "Shared"],
            path: "Features/StorageAnalysis",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),
        .target(
            name: "FeatureFileCleanup",
            dependencies: ["Core", "Shared"],
            path: "Features/FileCleanup",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),
        .target(
            name: "FeatureSettings",
            dependencies: ["Core", "Shared"],
            path: "Features/Settings",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),
        .target(
            name: "FeaturePurchase",
            dependencies: ["Core", "Shared"],
            path: "Features/Purchase",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),

        // Application shell: routing, the window and the page router. A library
        // so the Xcode app target can link it as a package product.
        .target(
            name: "AppShell",
            dependencies: [
                "Core",
                "Shared",
                "FeatureDashboard",
                "FeatureScan",
                "FeatureJunkCleanup",
                "FeatureUninstaller",
                "FeatureStorageAnalysis",
                "FeatureFileCleanup",
                "FeatureSettings",
                "FeaturePurchase",
            ],
            path: "App/Shell",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings
        ),

        // The executable is just the entry point. The same file is compiled by the
        // Xcode app target, so the two builds cannot diverge.
        .executableTarget(
            name: "SiftApp",
            dependencies: ["AppShell"],
            path: "App/Entry",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings,
            linkerSettings: runtimeLinkerSettings
        ),

        // Self-test executable. Runs the same checks as `Tests/` without XCTest,
        // which the Command Line Tools do not provide.
        .executableTarget(
            name: "SiftSelfTest",
            dependencies: ["Core", "Shared"],
            path: "SelfTest",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings,
            linkerSettings: runtimeLinkerSettings
        ),

        // Test suites. XCTest is the framework of record here because the
        // shipping toolchain is Xcode's, which provides it alongside Swift
        // Testing; these targets are what `swift test` and the Xcode test plan
        // both run.
        .testTarget(
            name: "SiftTests",
            dependencies: ["Shared", "Core"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v6)] + runtimeSwiftSettings,
            linkerSettings: runtimeLinkerSettings
        ),
    ]
)
