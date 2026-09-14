import SkyrCore
import SwiftUI

struct IndexingView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library

    private var indexer: LibraryIndexer { model.indexer }

    var body: some View {
        SetupPage(step: .indexing) {
            progress
        }
        .skyrBackground(Palette.neutralTint)
        .navigationBarBackButtonHidden(true)
        .hidesNavigationBar()
        .bareWindow()
    }

    private var progress: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(model.indexedCount, format: .number)
                .font(.system(size: 56 * Metrics.scale, weight: .light))
                .monospacedDigit()
                .kerning(-1.5 * Metrics.scale)
                .contentTransition(.numericText(value: Double(model.indexedCount)))
                .animation(.default, value: model.indexedCount)
            Text(title)
                .font(Metrics.scale > 1 ? .title3 : .subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            if let subtitle {
                Text(subtitle)
                    .font(Metrics.scale > 1 ? .body : .footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .padding(.horizontal, 12)
            }
            Group {
                if model.isDemo {
                    ProgressView(value: Double(model.demoCount) / Double(SampleLibrary.displayedTrackTotal))
                } else if indexer.isScanning {
                    ProgressView()
                        .controlSize(.regular)
                } else if model.indexingFailure != nil {
                    ProgressView(value: 0)
                } else {
                    ProgressView(value: indexer.enrichProgress)
                }
            }
            .tint(Palette.ink)
            .frame(width: 160 * Metrics.scale)
            .padding(.top, 28)
            .animation(.easeOut(duration: 0.25), value: indexer.enrichProgress)
            Spacer()
            if model.indexingFailure != nil {
                Button {
                    model.retryIndexing()
                } label: {
                    Text("Try again")
                        .font(.headline)
                        .foregroundStyle(Palette.onInk)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .tint(Palette.ink)
                Button("Choose another folder") {
                    model.chooseAnotherFolder()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            } else {
                Button {
                    model.openLibrary()
                } label: {
                    Text("Open library")
                        .font(.headline)
                        .foregroundStyle(model.isIndexed ? Palette.onInk : .secondary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .tint(model.isIndexed ? Palette.ink : Color.secondary.opacity(0.25))
                .disabled(!model.isIndexed)
                .animation(.easeInOut(duration: 0.4), value: model.isIndexed)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .connectColumn(width: 420)
    }

    private var title: String {
        if let failure = model.indexingFailure { return failure.title }
        if model.isDemo { return model.isIndexed ? "Library ready" : "Indexing your music" }
        switch indexer.phase {
        case .scanning: return "Scanning your music"
        case .enriching: return "Library ready"
        case .done: return "Library ready"
        default: return "Indexing your music"
        }
    }

    private var subtitle: String? {
        if let failure = model.indexingFailure { return failure.detail }
        if model.isDemo {
            return model.isIndexed ? "3,412 albums · 1,208 artists · 1.9 TB" : "Reading tags, artwork and folder structure…"
        }
        switch indexer.phase {
        case .scanning:
            return "\(indexer.foldersScanned.formatted()) folders scanned"
        case .enriching:
            return "\(library.catalogue.detail)\nReading tags and covers in the background · \(Int((indexer.enrichProgress * 100).rounded()))%"
        case .done:
            return library.catalogue.detail
        default:
            return "Reading tags, artwork and folder structure…"
        }
    }
}
