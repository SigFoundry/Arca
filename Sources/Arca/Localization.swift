import Foundation

enum L10n {
    private static var bundle: Bundle {
#if SWIFT_PACKAGE
        return .module
#else
        return .main
#endif
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: args)
    }
}
