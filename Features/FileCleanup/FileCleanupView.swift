import Core
import Shared
import SwiftUI

/// File cleanup: large files, old files and duplicates (§5.5).
///
/// Each mode is a filtered view of the same scan results, so the selection and
/// confirmation flow is identical to junk cleanup. The duplicate mode is the one
/// with its own rules: only the user's chosen folders, only per-group
/// confirmation, and never a system directory.
public struct FileCleanupView: View {
    @EnvironmentObject private var environment: AppEnvironment
    private let onRequestPurchase: () -> Void
    @State private var mode: Mode = .large
    @State private var hasScanned = false
    @State private var isScanning = false
    @State private var chosenFolders: [URL] = []
    @State private var showFolderPicker = false

    public enum Mode: String, CaseIterable {
        case large
        case old
        case duplicates

        var titleKey: LocalizationKey {
            switch self {
            case .large: .filesModeLarge
            case .old: .filesModeOld
            case .duplicates: .filesModeDuplicates
            }
        }

        /// The categories this mode shows.
        var categories: [CleanupCategory] {
            switch self {
            case .large: [.largeFiles]
            case .old: [.oldFiles]
            case .duplicates: [.duplicateFiles]
            }
        }
    }

    public init(onRequestPurchase: @escaping () -> Void = {}) {
        self.onRequestPurchase = onRequestPurchase
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                PageHeader(titleKey: .filesTitle) {
                    Picker(String(), selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { mode in
                            Text(mode.titleKey.localized).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                    .onChange(of: mode) { _ in
                        hasScanned = false
                    }
                }

                thresholdNote

                if mode == .duplicates {
                    DuplicateScopeCard(
                        folders: chosenFolders,
                        onAdd: { showFolderPicker = true },
                        onRemove: { url in chosenFolders.removeAll { $0 == url } },
                        onScan: { Task { await scan() } },
                        isScanning: isScanning
                    )
                }

                if !hasScanned {
                    ScanGateCard(
                        titleKey: mode.titleKey,
                        detailKey: mode == .duplicates ? .filesRequiresAuthorization : .cleanupExplanationLargeFiles,
                        onStart: { Task { await scan() } }
                    )
                } else {
                    SelectionBar(
                        cleanup: environment.cleanup,
                        environment: environment,
                        onRequestPurchase: onRequestPurchase
                    )
                    ScanResultsView(scan: environment.scan, cleanup: environment.cleanup)
                }
            }
            .padding(SiftMetrics.spacingXL)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                chosenFolders.append(contentsOf: urls)
            }
        }
    }

    private var thresholdNote: some View {
        SiftPanel(padding: SiftMetrics.spacingM) {
            HStack(spacing: SiftMetrics.spacingM) {
                Image(systemName: "info.circle")
                    .foregroundStyle(SiftColor.accent)
                    .accessibilityHidden(true)
                switch mode {
                case .large:
                    Text(
                        LocalizationKey.filesThresholdLarge.localized(
                            SiftFormat.bytes(environment.preferences.largeFileThresholdBytes)
                        )
                    )
                    .font(SiftFont.body)
                case .old:
                    Text(
                        LocalizationKey.filesThresholdOld.localized(environment.preferences.oldFileThresholdDays)
                    )
                    .font(SiftFont.body)
                case .duplicates:
                    Text(LocalizationKey.cleanupExplanationDuplicates.localized)
                        .font(SiftFont.body)
                }
                Spacer()
            }
        }
    }

    private func scan() async {
        isScanning = true
        defer { isScanning = false }
        environment.cleanup.resetForNewScan()

        var request = await environment.makeScanRequest(includeDuplicates: mode == .duplicates)
        if mode == .duplicates {
            // Only the user's chosen folders, plus the safe defaults. A system
            // directory is never added here.
            let defaults = environment.defaultDuplicateRoots()
            request.duplicateRoots = Array(Set(defaults + chosenFolders.map(\.path)))
        } else {
            request.includeDuplicates = false
        }

        await environment.scan.start(request)
        if mode == .duplicates {
            await environment.scan.loadDuplicateGroups()
        }
        let page = await environment.scan.page(
            offset: 0,
            limit: 200,
            sort: .size,
            category: mode.categories.first
        )
        environment.cleanup.setItems(page.items.map { $0.asCleanupItem() }, preselect: false)
        hasScanned = true
    }
}

/// The duplicate scope: which folders are searched, and the warning that nothing
/// outside them is touched.
struct DuplicateScopeCard: View {
    let folders: [URL]
    let onAdd: () -> Void
    let onRemove: (URL) -> Void
    let onScan: () -> Void
    let isScanning: Bool

    var body: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack {
                    Text(LocalizationKey.filesChooseFolders.localized)
                        .font(SiftFont.sectionTitle)
                    Spacer()
                    Button {
                        onAdd()
                    } label: {
                        Label(LocalizationKey.filesAddFolder.localized, systemImage: "folder.badge.plus")
                    }
                }
                Text(LocalizationKey.filesRequiresAuthorization.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !folders.isEmpty {
                    ForEach(folders, id: \.path) { url in
                        HStack(spacing: SiftMetrics.spacingM) {
                            Image(systemName: "folder")
                                .foregroundStyle(SiftColor.accent)
                                .accessibilityHidden(true)
                            Text(CleanupItem.abbreviate(url.path))
                                .font(SiftFont.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                onRemove(url)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(LocalizationKey.commonRemove.localized))
                        }
                    }
                }
                Button {
                    onScan()
                } label: {
                    Text(LocalizationKey.filesScanDuplicates.localized)
                        .font(SiftFont.bodyEmphasis)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)
            }
        }
    }
}
