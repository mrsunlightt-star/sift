// swift-tools-version: 6.0
import PackageDescription

// Minimum supported version is macOS 13 Ventura, per the development spec
// (§6.1). Anything newer must be guarded by an availability check with a
// Ventura fallback.
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
        // The Rust scanner core, exposed through its C ABI.
        //
        // It is a *conditional* dependency: SwiftPM links it only when
        // pkg-config finds the static library that
        // `Scripts/build-rust-xcframework.sh` produces. `swift build` without the
        // Rust step still produces a complete app, because `Core` guards every
        // Rust call site with `#if canImport(SiftScanner)`. Adding the target
        // unconditionally would make the manifest itself fail to resolve, which
        // would stop even the Swift-only build.
        .systemLibrary(
            name: "SiftScanner",
            path: "Bridge",
            pkgConfig: "SiftScanner",
            providers: [.brew(["rust"])]
        ),

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
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Domain models, rules, permissions, file operations, reports,
        // entitlements, logging and the scanning engines.
        .target(
            name: "Core",
            dependencies: ["Shared", "SiftScanner"],
            path: "Core",
            resources: [.process("Resources/CleaningRules.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Feature view models and views. Split by feature so a change to the
        // uninstaller cannot break the storage analysis build.
        .target(
            name: "FeatureDashboard",
            dependencies: ["Core", "Shared"],
            path: "Features/Dashboard",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FeatureScan",
            dependencies: ["Core", "Shared"],
            path: "Features/Scan",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FeatureJunkCleanup",
            dependencies: ["Core", "Shared"],
            path: "Features/JunkCleanup",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FeatureUninstaller",
            dependencies: ["Core", "Shared"],
            path: "Features/Uninstaller",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FeatureStorageAnalysis",
            dependencies: ["Core", "Shared"],
            path: "Features/StorageAnalysis",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FeatureFileCleanup",
            dependencies: ["Core", "Shared"],
            path: "Features/FileCleanup",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FeatureSettings",
            dependencies: ["Core", "Shared"],
            path: "Features/Settings",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FeaturePurchase",
            dependencies: ["Core", "Shared"],
            path: "Features/Purchase",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Application shell: routing, environment composition and the window.
        .executableTarget(
            name: "SiftApp",
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
            path: "App",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Self-test executable. Runs the same checks as `Tests/` without XCTest,
        // which the Command Line Tools do not provide.
        .executableTarget(
            name: "SiftSelfTest",
            dependencies: ["Core", "Shared"],
            path: "SelfTest",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Test suites. XCTest is the framework of record here because the
        // shipping toolchain is Xcode's, which provides it alongside Swift
        // Testing; these targets are what `swift test` and the Xcode test plan
        // both run.
        .testTarget(
            name: "SiftTests",
            dependencies: ["Shared", "Core"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
