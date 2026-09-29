import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, korean = "ko", english = "en"

    public func resolvedCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if self != .system { return rawValue }
        for preference in preferredLanguages {
            let code = Locale(identifier: preference).language.languageCode?.identifier
            if code == "ko" || code == "en" { return code! }
        }
        return "en"
    }
}

/// Foundation-only localization shared by UI labels and service errors.
/// Persisted enum raw values, filenames, and user-supplied names stay unchanged.
public enum L10n {
    public static let preferenceKey = "appLanguage"
    public static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system
    }
    public static var locale: Locale { Locale(identifier: language.resolvedCode()) }
    private static let bundles: [String: Bundle] = {
        #if SWIFT_PACKAGE
        let base = Bundle.module
        #else
        let base = Bundle.main
        #endif
        return Dictionary(uniqueKeysWithValues: ["en","ko"].compactMap { code in
            guard let path = base.path(forResource: code,ofType: "lproj"),let bundle = Bundle(path: path) else { return nil }
            return (code,bundle)
        })
    }()
    public static func tr(_ key: String,language: AppLanguage? = nil) -> String {
        let code = (language ?? self.language).resolvedCode()
        return bundles[code]?.localizedString(forKey: key,value: key,table: "Localizable") ?? key
    }
    /// Translate generated mask labels without rewriting names in saved documents.
    public static func maskName(_ mask: LocalMask,language: AppLanguage? = nil) -> String {
        let prefix = mask.kind.rawValue
        if mask.name == prefix { return tr(prefix,language: language) }
        if mask.name.hasPrefix(prefix + " ") {
            let suffix = mask.name.dropFirst(prefix.count + 1)
            if !suffix.isEmpty && suffix.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return tr(prefix,language: language) + " " + suffix
            }
        }
        return mask.name
    }
    public static func format(_ key: String,_ arguments: CVarArg...) -> String {
        format(key,arguments: arguments,language: language)
    }
    static func format(_ key: String,arguments: [CVarArg],language: AppLanguage) -> String {
        String(format: tr(key,language: language),locale: Locale(identifier: language.resolvedCode()),arguments: arguments)
    }
}
