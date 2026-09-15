import SkyrCore
import SwiftUI

/// Trailing navigation button showing library scan status with animated or static icon.
/// When scanning: animated icon (respects Reduce Motion). When idle: calm cloud-done icon.
/// Tapping shows a detail sheet with last scan info and rescan option.
struct ScanStatusButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDetail = false

    private var isScanning: Bool { model.isScanning }

    var body: some View {
        Button {
            showsDetail = true
        } label: {
            Group {
                if isScanning {
                    scanningIcon
                } else {
                    idleIcon
                }
            }
            .font(.body.weight(.medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows scan details")
        .sheet(isPresented: $showsDetail) {
            ScanDetailSheet()
        }
    }

    private var scanningIcon: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .symbolEffect(
                .variableColor.iterative,
                options: .repeating,
                isActive: isScanning
            )
            .symbolEffectsRemoved(reduceMotion)
            .foregroundStyle(.primary)
    }

    private var idleIcon: some View {
        Image(systemName: "checkmark.icloud")
            .foregroundStyle(.secondary)
    }

    private var accessibilityLabel: String {
        isScanning ? "Library scanning" : "Library up to date"
    }

    private var accessibilityValue: String {
        if isScanning {
            if let text = model.indexer.statusText {
                return text
            }
            return "Scanning in progress"
        }
        return model.lastScanText
    }
}

/// Sheet showing scan details: last scan time, current status, and rescan option.
struct ScanDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    private var isScanning: Bool { model.isScanning }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                    lastScanRow
                    trackCountRow
                }

                if !isScanning {
                    Section {
                        Button {
                            model.rescan()
                        } label: {
                            Label("Scan for New Music", systemImage: "arrow.clockwise")
                        }
                    } footer: {
                        Text("Checks the folder for music added since the last scan.")
                    }
                }
            }
            .navigationTitle("Library Scan")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetDetents([.medium])
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Label {
                Text("Status")
            } icon: {
                Image(systemName: isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .foregroundStyle(isScanning ? .orange : .green)
            }
            Spacer()
            if isScanning {
                if let text = model.indexer.statusText {
                    Text(text)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scanning…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Up to date")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var lastScanRow: some View {
        HStack {
            Label("Last scanned", systemImage: "clock")
            Spacer()
            Text(model.lastScanText)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trackCountRow: some View {
        HStack {
            Label("Tracks", systemImage: "music.note")
            Spacer()
            Text("\(library.catalogue.trackCount)")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Idle") {
    NavigationStack {
        Text("Library")
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ScanStatusButton()
                }
            }
    }
    .environment(AppModel(library: LibraryStore()))
    .environment(LibraryStore())
}
