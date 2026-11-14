import Foundation

/// Personal settings shared with `tb`, kept out of the repo in
/// `~/.config/claudetouchbar/config` (see `config.example`). Plain
/// `KEY="value"` lines — the same file `tb` sources as shell. Read once at
/// launch: restart the app after editing it.
enum Config {

    static let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/claudetouchbar/config")

    private static let values: [String: String] = {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
        }
        return result
    }()

    private static func value(_ key: String) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        return value
    }

    /// Account name as shown in Mail.app; nil disables the mail features.
    static var mailAccount: String? { value("MAIL_ACCOUNT") }
    /// Comma-separated calendar names the assistant may pick from.
    static var calendars: String? { value("CALENDARS") }
    /// Comma-separated vault folders the assistant may file notes into.
    static var noteFolders: String? { value("NOTE_FOLDERS") }
    static var noteDefaultFolder: String { value("NOTE_DEFAULT_FOLDER") ?? "Quicknote" }
    static var hasVault: Bool { value("VAULT") != nil }
}
