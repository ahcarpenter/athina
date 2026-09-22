import Foundation

/// Apps under which Athina never captures, reads text, or journals.
public enum ExcludedApps {
    /// Common password managers and Keychain Access.
    public static let defaults: [String] = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.DashlaneMacOS",
        "com.dashlane.Dashlane",
        "org.keepassxc.keepassxc",
        "com.markmcguill.strongbox",
        "in.sinew.Enpass-Desktop",
        "com.nordpass.macos",
        "com.protonmail.pass",
        "com.roboform.mac",
    ]

    /// Trims, drops empties and duplicates, and keeps the user's order.
    public static func normalized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let key = id.lowercased()
            if seen.insert(key).inserted {
                out.append(id)
            }
        }
        return out
    }

    /// Case-insensitive match against a lowercase set.
    public static func matches(bundleID: String?, excluded: Set<String>) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return excluded.contains(bundleID.lowercased())
    }
}
