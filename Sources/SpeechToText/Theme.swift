// The same design tokens as Cleaner (github.com/ciro-maciel/cleaner).
import SwiftUI
import AppKit
import CoreText

/// The Zen design system in SwiftUI: ten grays, Montserrat in four weights, radius zero, no shadow,
/// 1px rules in gray.2.
enum Zen {
    // The ramp. 0–3 surface and structure, 4–9 ink.
    static let gray0 = Color(hex: 0xFFFFFF)
    static let gray1 = Color(hex: 0xF9FAFB)
    static let gray2 = Color(hex: 0xF3F4F6)
    static let gray3 = Color(hex: 0xE5E7EB)
    static let gray4 = Color(hex: 0x9CA3AF)
    static let gray5 = Color(hex: 0x6B7280)
    static let gray6 = Color(hex: 0x4B5563)
    static let gray7 = Color(hex: 0x374151)
    static let gray8 = Color(hex: 0x1F2937)
    static let gray9 = Color(hex: 0x11181C)
    /// Loss and errors only (red.6 / red.7 of Mantine).
    static let red6 = Color(hex: 0xFA5252)
    static let red7 = Color(hex: 0xF03E3E)
    static let red2 = Color(hex: 0xFFC9C9)

    enum Weight { case regular, medium, bold, extraBold, black
        var postScript: String {
            switch self {
            case .regular: return "Montserrat-Regular"
            case .medium: return "Montserrat-Medium"
            case .bold: return "Montserrat-Bold"
            case .extraBold: return "Montserrat-ExtraBold"
            case .black: return "Montserrat-Black"
            }
        }
    }

    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font { .custom(weight.postScript, fixedSize: size) }

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static let rule: CGFloat = 1
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - The four text roles

extension View {
    /// Label: the announcement. 10–13px, 800, uppercase, tracking 1.5, gray.4/5.
    func zenLabel(_ size: CGFloat = 10, color: Color = Zen.gray4) -> some View {
        font(Zen.font(size, .extraBold)).tracking(1.5).textCase(.uppercase).foregroundStyle(color)
    }
    /// Data: what is compared in a column. 13px, 500, gray.7.
    func zenData(_ size: CGFloat = 13, color: Color = Zen.gray7) -> some View {
        font(Zen.font(size, .medium)).foregroundStyle(color)
    }
    /// Body: what is read in sequence. 15px, 500, gray.6.
    func zenBody(_ size: CGFloat = 15, color: Color = Zen.gray6) -> some View {
        font(Zen.font(size, .medium)).foregroundStyle(color).lineSpacing(size * 0.4)
    }
    /// Note: the verification under a strong number. 13px, gray.6.
    func zenNote() -> some View {
        font(Zen.font(13, .medium)).foregroundStyle(Zen.gray6).lineSpacing(5)
    }
    /// Display: the declaration. 900, tracking -0.04em, gray.9.
    func zenDisplay(_ size: CGFloat) -> some View {
        font(Zen.font(size, .black)).tracking(-0.04 * size).foregroundStyle(Zen.gray9)
    }

    func zenBorder(_ color: Color = Zen.gray2) -> some View {
        overlay(Rectangle().strokeBorder(color, lineWidth: Zen.rule))
    }
}

// MARK: - Icons and illustrations

/// Tabler icon, outline, stroke 1.5, from Resources/Icons (template PDFs).
struct Icon: View {
    let name: String
    var size: CGFloat = 16
    var color: Color = Zen.gray7

    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "Icons"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        cache[name] = img
        return img
    }

    var body: some View {
        Group {
            if let img = Icon.image(name) {
                Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high)
            } else {
                Rectangle().fill(Color.clear)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(color)
    }
}

