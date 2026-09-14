import SkyrCore
import SwiftUI

/// The album or playlist download control: an arrow at rest, a progress ring while files come down, and a check
/// once everything is there. Completion implodes the ring, pops the check out and fires a small burst.
struct DownloadButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: DownloadState
    let action: () -> Void
    @State private var celebration = 0

    private enum Phase { case idle, downloading, downloaded }
    private var phase: Phase {
        switch state {
        case .none, .failed, .partial, .cancelled: .idle
        case .downloading: .downloading
        case .downloaded: .downloaded
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .none:
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.bold))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                case .failed, .partial, .cancelled:
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.bold))
                        .transition(.opacity)
                case .downloading(let fraction, _, _):
                    ProgressRing(fraction: fraction)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .scale(scale: 0.5).combined(with: .opacity),
                            removal: .scale(scale: 0.15).combined(with: .opacity)
                        ))
                case .downloaded:
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Palette.onInk)
                        .symbolEffect(.bounce, options: .speed(1.1), value: celebration)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(width: 50, height: 50)
            .background {
                Circle()
                    .fill(Palette.ink)
                    .opacity(phase == .downloaded ? 1 : 0)
                    .scaleEffect(phase == .downloaded || reduceMotion ? 1 : 0.3)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .overlay {
                if !reduceMotion { Burst(trigger: celebration) }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.5, bounce: 0.38), value: phase)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .symbolEffectsRemoved(reduceMotion)
        .onChange(of: state) { old, new in
            // Also celebrate when every song was already here and the download finished at once.
            if old != .downloaded, new == .downloaded { celebration += 1 }
        }
        .sensoryFeedback(.success, trigger: celebration)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .none: "Download"
        case .downloading(_, let done, let total): "Downloading, \(done) of \(total) songs. Cancel download"
        case .downloaded: "Downloaded. Remove download"
        case .failed(let message): "Download failed. \(message). Retry missing songs"
        case .partial(let done, let total, _): "\(done) of \(total) songs saved. Retry missing songs"
        case .cancelled(let done, let total): "Download cancelled, \(done) of \(total) songs saved. Retry download"
        }
    }
}

/// Circular progress with a small stop mark in the middle, so it also reads as "tap to cancel".
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Palette.ink)
                .frame(width: 9, height: 9)
        }
        .padding(11)
        .accessibilityHidden(true)
    }
}

/// Tiny ring for song rows while their file is coming down.
struct MiniProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, fraction))
                .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
        }
        .frame(width: 13, height: 13)
        .accessibilityLabel("Downloading, \(Int((fraction * 100).rounded())) percent")
    }
}

/// Eight dots that fly out and fade when a download completes.
private struct Burst: View {
    let trigger: Int

    var body: some View {
        KeyframeAnimator(initialValue: 0.0, trigger: trigger) { t in
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) / 8 * 2 * .pi
                    Circle()
                        .fill(Palette.ink)
                        .frame(width: 5, height: 5)
                        .scaleEffect(1 - t * 0.6)
                        .opacity(trigger == 0 ? 0 : max(0, 1 - t * 1.15))
                        .offset(x: cos(angle) * (14 + t * 28), y: sin(angle) * (14 + t * 28))
                }
            }
        } keyframes: { _ in
            CubicKeyframe(1.0, duration: 0.65)
        }
        .allowsHitTesting(false)
    }
}
