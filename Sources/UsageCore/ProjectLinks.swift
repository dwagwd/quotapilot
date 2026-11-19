import Foundation

/// The project's public addresses, in one place for the app's menu and the command-line tool.
public enum ProjectLinks {
    public static let website = URL(string: "https://aiquotawatch.pages.dev/")!
    public static let community = URL(string: "https://aiquotawatch.pages.dev/#community")!
    public static let repository = URL(string: "https://github.com/dwagwd/quotapilot")!
    public static let newIssue = URL(string: "https://github.com/dwagwd/quotapilot/issues/new/choose")!
    /// Empty until a sponsor page exists; `scripts/set-sponsor.sh` fills it in together with the website and READMEs.
    static let sponsorAddress = ""
    /// The sponsor page, or nil while there is none. Only https addresses are used.
    public static var sponsor: URL? { sponsorURL(from: sponsorAddress) }

    static func sponsorURL(from text: String) -> URL? {
        guard let link = URL(string: text.trimmingCharacters(in: .whitespaces)), link.scheme == "https", link.host?.isEmpty == false else { return nil }
        return link
    }

    /// Where `QuotaPilot.app` is, given the path of the `quotapilot` tool inside it (`…/QuotaPilot.app/Contents/Helpers/quotapilot`).
    /// Symlinks (Homebrew's `bin/quotapilot`) must be resolved by the caller first. Nil when the tool is not inside the app.
    public static func appBundle(containing tool: URL) -> URL? {
        let parts = tool.standardizedFileURL.pathComponents
        guard parts.count >= 4, parts[parts.count - 2] == "Helpers", parts[parts.count - 3] == "Contents", parts[parts.count - 4].hasSuffix(".app") else { return nil }
        return tool.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The version-independent Homebrew path for an app inside `…/Cellar/quotapilot/<version>/`, which `brew upgrade`
    /// removes: the same prefix with `/opt/quotapilot/` instead. Nil when the path is not in that Cellar folder,
    /// or when `exists` says the stable path is not there.
    public static func stableHomebrewApp(for app: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        let path = app.standardizedFileURL.path
        guard let range = path.range(of: "/Cellar/quotapilot/") else { return nil }
        let rest = path[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
        let stable = String(path[..<range.lowerBound]) + "/opt/quotapilot/" + rest[rest.index(after: slash)...]
        return exists(stable) ? URL(fileURLWithPath: stable) : nil
    }
}
