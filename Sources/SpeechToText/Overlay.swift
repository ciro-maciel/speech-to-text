// The overlay: the gray.9 band over whatever app is in front, on the display with the cursor,
// clear of the Dock and the menu bar. The Tauri build's overlay-visualizer.html in SwiftUI: 40
// tall, 14 at the sides, 12 between parts, the state 10/800 in caps, the rest 12/500. red is
// the only color and it only means "error". Outside the main window, so no sidebar.
import AppKit
import Combine
import SwiftUI

struct OverlayView: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings: AppSettings

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(height: 40)
            .frame(minWidth: 200, alignment: .leading)
            .background(isError ? Zen.gray0 : Zen.gray9)
            .overlay(Rectangle().strokeBorder(isError ? Self.red : .clear, lineWidth: 1))
            .fixedSize()
    }

    static let red = Color(hex: 0xE03131)
    private var isError: Bool { if case .error = dictation.overlay { return true }; return false }

    @ViewBuilder private var content: some View {
        switch dictation.overlay {
        case .hidden:
            EmptyView()
        case let .listening(translate, locked):
            let isDead = recorder.isSignalDead
            HStack(spacing: 12) {
                label(isDead ? L("hud.micSilent") : L(translate ? "hud.listeningTranslate" : "hud.listening"), muted: isDead)
                LevelBars(level: recorder.level, color: isDead ? Zen.gray7 : Zen.gray0)
                if locked {
                    meta(L("hud.handsFree"))
                } else if settings.overlayShowTimer, let since = dictation.listeningSince {
                    TimelineView(.periodic(from: since, by: 0.25)) { context in
                        meta(Self.clock(context.date.timeIntervalSince(since)))
                    }
                }
            }
        case .transcribing:
            HStack(spacing: 12) { label(L("hud.transcribing")); Track(); meta(L("hud.onDevice")) }
        case .refining:
            HStack(spacing: 12) { label(L("hud.refining")); Track(); meta("OpenRouter") }
        case let .translating(target):
            HStack(spacing: 12) { label(L("hud.translating", target.uppercased())); Track(); meta("OpenRouter") }
        case let .pasted(text, words):
            HStack(spacing: 12) {
                label(L("hud.pasted"))
                if settings.overlayShowText {
                    Text(text).font(Zen.font(12, .medium)).foregroundStyle(Zen.gray3).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 320, alignment: .leading)
                }
                meta(L("hud.words", count: words))
            }
        case .nothing:
            HStack(spacing: 12) { label(L("hud.nothingHeard"), muted: true); meta(L("hud.nothingPasted")) }
        case .cancelled:
            HStack(spacing: 12) { label(L("hud.cancelled"), muted: true); meta(L("hud.nothingPasted")) }
        case .needsPermission:
            HStack(spacing: 12) {
                label(L("hud.copied"))
                Button {
                    Permissions.requestAccessibility()
                    Permissions.openSettings("Privacy_Accessibility")
                } label: {
                    Text(L("hud.allow")).font(Zen.font(10, .extraBold)).tracking(1).textCase(.uppercase)
                        .foregroundStyle(Zen.gray9).padding(.horizontal, 8).padding(.vertical, 5).background(Zen.gray0)
                }
                .buttonStyle(.plain)
            }
        case let .error(message):
            HStack(spacing: 12) {
                Text(L("hud.error")).font(Zen.font(10, .extraBold)).tracking(1.5).textCase(.uppercase).foregroundStyle(Self.red)
                Text(message).font(Zen.font(12, .medium)).foregroundStyle(Self.red).lineLimit(1)
            }
        }
    }

    private func label(_ text: String, muted: Bool = false) -> some View {
        Text(text).font(Zen.font(10, .extraBold)).tracking(1.5).textCase(.uppercase)
            .foregroundStyle(muted ? Zen.gray4 : Zen.gray0).lineLimit(1).fixedSize()
    }

    private func meta(_ text: String) -> some View {
        Text(text).font(Zen.font(12, .medium)).monospacedDigit().foregroundStyle(Zen.gray4).lineLimit(1).fixedSize()
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Twelve bars of 3, 2 apart, up to 18 tall, following the voice with a slight wobble.
private struct LevelBars: View {
    let level: Double
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * abs(sin(t * 1000 / 120 + Double(i) * 0.9))
                    Rectangle().fill(color).frame(width: 3, height: 2 + 16 * min(1, level) * wobble)
                }
            }
            .frame(height: 18)
        }
    }
}

/// The working track: a gray.7 line with a white piece sliding through it.
private struct Track: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack(alignment: .leading) {
                Rectangle().fill(Zen.gray7)
                Rectangle().fill(Zen.gray0).frame(width: 64 * 0.3).offset(x: 64 * (-0.3 + 1.3 * phase))
            }
            .frame(width: 64, height: 2)
            .clipped()
        }
    }
}

@MainActor
final class OverlayController {
    private let panel: NSPanel
    private let host: NSHostingView<OverlayView>
    private var watch: AnyCancellable?
    private let dictation: Dictation
    private let settings: AppSettings

    init(dictation: Dictation, recorder: Recorder, settings: AppSettings) {
        self.dictation = dictation
        self.settings = settings
        host = NSHostingView(rootView: OverlayView(dictation: dictation, recorder: recorder, settings: settings))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = host

        watch = dictation.$overlay.receive(on: RunLoop.main).sink { [weak self] state in
            self?.update(state)
        }
    }

    private var anchorScreen: NSScreen?

    private func update(_ state: OverlayState) {
        guard state != .hidden else {
            panel.orderOut(nil)
            anchorScreen = nil
            return
        }
        // Only the "allow" button takes the mouse; everything else lets clicks through.
        panel.ignoresMouseEvents = state != .needsPermission
        // A new dictation picks the display with the cursor; its later states stay there.
        if !panel.isVisible || anchorScreen == nil {
            anchorScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        // Lay out after SwiftUI has the new state.
        DispatchQueue.main.async { [self] in
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            panel.setContentSize(size)
            place(size)
            panel.orderFrontRegardless()
        }
    }

    private func place(_ size: CGSize) {
        guard let area = anchorScreen?.visibleFrame else { return }
        let margin: CGFloat = 12
        let left = area.minX + margin, center = area.midX - size.width / 2, right = area.maxX - size.width - margin
        let top = area.maxY - size.height - margin, middle = area.midY - size.height / 2, bottom = area.minY + margin
        let origin: CGPoint
        switch settings.overlayPosition {
        case .topLeft: origin = CGPoint(x: left, y: top)
        case .top: origin = CGPoint(x: center, y: top)
        case .topRight: origin = CGPoint(x: right, y: top)
        case .left: origin = CGPoint(x: left, y: middle)
        case .center: origin = CGPoint(x: center, y: middle)
        case .right: origin = CGPoint(x: right, y: middle)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        case .bottom: origin = CGPoint(x: center, y: bottom)
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        }
        panel.setFrameOrigin(origin)
    }
}
