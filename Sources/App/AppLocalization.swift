import Foundation

enum AppStrings {
    static var locale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans") }
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        String(localized: String.LocalizationValue(key), bundle: bundle)
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
    static func connection(_ value: String?) -> String {
        switch value {
        case "ready": return text("Ready")
        case "busy": return text("Busy")
        case "recovery": return text("Recovery required")
        case "disconnected": return text("Disconnected")
        case "error": return text("Printer error")
        default: return text("Unknown")
        }
    }
    static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale))
    }
}
