// Small pieces of the panel. ZenButtonStyle and ButtonLabel are the Cleaner's
// (applications/apps/cleaner/desktop/Sources/Cleaner/UI/Theme.swift), primary and secondary only.
import SwiftUI

struct ZenButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Zen.font(11, .extraBold))
            .tracking(1)
            .textCase(.uppercase)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: height)
            .foregroundStyle(kind == .primary ? .white : Zen.gray9)
            .background(kind == .primary ? Zen.gray9 : Zen.gray0)
            .overlay(Rectangle().strokeBorder(kind == .secondary ? Zen.gray9 : .clear, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .contentShape(Rectangle())
    }
}

struct ButtonLabel: View {
    let title: String
    var icon: String? = nil
    var color: Color = Zen.gray9
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Icon(name: icon, size: 14, color: color) }
            Text(title)
        }
    }
}

/// A block label, 10/800 gray.5, 10 above its content.
struct BlockLabel: View {
    let text: String
    var body: some View { Text(text).zenLabel(10, color: Zen.gray5).padding(.bottom, 10) }
}

/// Cells that touch, with 1px gray.2 rules between them.
struct CellRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 0) { content }
            .fixedSize(horizontal: false, vertical: true)
            .zenBorder()
    }
}

/// One cell: label, strong value (display 22/900), and the note that makes it checkable.
struct Cell<Value: View>: View {
    let label: String
    let note: String
    var isLast = false
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).zenLabel(10)
            HStack(spacing: 10) { value }.padding(.top, 8).padding(.bottom, 4)
            Text(note).zenData(12, color: Zen.gray5).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .trailing) { if !isLast { Rectangle().fill(Zen.gray2).frame(width: 1) } }
    }
}

/// Rows that touch, 1px gray.2 between them, inside a 1px frame.
struct Rows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }.zenBorder()
    }
}

struct RowRule: View {
    var body: some View { Rectangle().fill(Zen.gray2).frame(height: 1) }
}

// MARK: - Settings rows

/// A settings list: rows separated by 1px gray.2, a rule on top and under the last one.
struct SettingRows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .overlay(alignment: .top) { Rectangle().fill(Zen.gray2).frame(height: 1) }
    }
}

/// Title 14/700 gray.9 with its hint 12/500 gray.5 on the left, the control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var hint: String = ""
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Zen.font(14, .bold)).foregroundStyle(Zen.gray9)
                if !hint.isEmpty {
                    Text(hint).font(Zen.font(12, .medium)).foregroundStyle(Zen.gray5).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 12) { control }.fixedSize()
        }
        .padding(.vertical, 12)
        // Behind, not over: an open ZenSelect's list must cover this rule.
        .background(alignment: .bottom) { Rectangle().fill(Zen.gray2).frame(height: 1) }
    }
}

/// A read-only value on the right of a setting row.
struct SettingValue: View {
    let text: String
    var body: some View { Text(text).font(Zen.font(13, .bold)).foregroundStyle(Zen.gray9) }
}

/// The house Select, from Clips (operations/videos/clips-swift/Sources/Clips/UI/TrayView.swift):
/// the Mantine Select of the web panels in our look. A square field with the chevron, gray.9
/// border while open; the list opens right under it, inside the window, in a gray.3 border
/// without shadow, the chosen item with the Tabler check. Never the system's menu.
/// Here the list floats over the rows below (Clips grows its tray instead), so the row that holds
/// an open select needs a higher zIndex than the rows under it.
struct ZenSelect: View {
    let value: String
    let choices: [(id: String, title: String)]
    var selected: String? = nil
    var isBusy = false
    var width: CGFloat = 240
    /// For the review's screens: the list already open.
    var startOpen = false
    let onPick: (String) -> Void
    @State private var open = false
    @State private var hover: String?

    var body: some View {
        Button { if !isBusy && !choices.isEmpty { open.toggle() } } label: {
            HStack(spacing: 10) {
                Text(isBusy ? L("select.applying") : value).font(Zen.font(13, .bold)).foregroundStyle(isBusy ? Zen.gray5 : Zen.gray9).lineLimit(1)
                Spacer(minLength: 0)
                Icon(name: "chevron-down", size: 14, color: Zen.gray6).rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 12).frame(width: width, height: 36)
            .background(Zen.gray0)
            .overlay(Rectangle().strokeBorder(open ? Zen.gray9 : Zen.gray3, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if open {
                VStack(spacing: 0) {
                    ForEach(choices, id: \.id) { choice in
                        let isChosen = choice.id == (selected ?? "")
                        Button { open = false; onPick(choice.id) } label: {
                            HStack(spacing: 10) {
                                Text(choice.title).font(Zen.font(13, isChosen ? .extraBold : .medium)).foregroundStyle(Zen.gray9).lineLimit(1)
                                Spacer(minLength: 0)
                                if isChosen { Icon(name: "check", size: 14, color: Zen.gray9) }
                            }
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(hover == choice.id ? Zen.gray1 : Zen.gray0)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hover = $0 ? choice.id : (hover == choice.id ? nil : hover) }
                    }
                }
                .padding(.vertical, 4)
                .frame(width: width)
                .background(Zen.gray0)
                .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
                .offset(y: 40)
            }
        }
        .onExitCommand { open = false }
        .onAppear { if startOpen { open = true } }
        .onChange(of: isBusy) { _, busy in if busy { open = false } }
    }
}

/// The microphone meter beside its combo: five bars of 3, 2 apart, 14 tall, bottom aligned.
struct MicMeter: View {
    let level: Double
    private let shape: [Double] = [0.55, 0.85, 1, 0.75, 0.5]
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Rectangle().fill(Zen.gray9).frame(width: 3, height: 2 + 12 * min(1, level * 2.2) * shape[i])
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}

/// A settings or history line: a fixed first column, the value, and a quiet note on the right.
struct DataRow: View {
    let label: String
    let value: String
    var detail: String = ""
    var labelWidth: CGFloat = 200

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(Zen.font(12, .bold)).foregroundStyle(Zen.gray7).frame(width: labelWidth, alignment: .leading)
            Text(value).font(Zen.font(13, .bold)).foregroundStyle(Zen.gray9).frame(maxWidth: .infinity, alignment: .leading)
            if !detail.isEmpty {
                Text(detail).zenData(12, color: Zen.gray5).multilineTextAlignment(.trailing).frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
