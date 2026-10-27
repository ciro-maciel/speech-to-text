// English and Brazilian Portuguese, following the Mac's language (no switch in the app).
// The tables are Resources/en.lproj and Resources/pt-BR.lproj/Localizable.strings, copied into
// the bundle by scripts/build.sh. Every on-screen string goes through L(...), never through
// Text("literal"), so a lookup can't silently miss: a key missing in Portuguese falls back to
// English, and only a key missing in both shows the key.
import Foundation

enum Localization {
    private static let english: Bundle? = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    private static let missing = "\u{1}missing"

    static func string(_ key: String) -> String {
        let value = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
        if value != missing { return value }
        return english?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    /// The language the app shows ("en" or "pt-BR"), as the bundle resolved it.
    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var isPortuguese: Bool { language.lowercased().hasPrefix("pt") }
    /// Numbers and times in the interface's language, not the system's.
    static var locale: Locale { Locale(identifier: isPortuguese ? "pt_BR" : "en_US") }
}

/// A localized string; with arguments, the table's value is a format ("%@", "%d").
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Localization.string(key)
    return args.isEmpty ? format : String(format: format, locale: Localization.locale, arguments: args)
}

/// One or other, by count: the key gets ".one" or ".other".
func L(_ key: String, count: Int) -> String {
    L(key + (count == 1 ? ".one" : ".other"), count)
}
