import Foundation

/// Finds a newer QuotaPilot release on GitHub. Pure parsing and comparison; the app does the network call,
/// the download and the signature checks.
public enum AppUpdate {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/dwagwd/quotapilot/releases/latest")!
    /// Developer ID team that signs official builds. An update signed by anyone else is refused.
    public static let teamID = ""
    public static let checkInterval: Double = 86400

    public struct Release: Equatable {
        public let version: String
        public let pageURL: URL
        public let assetURL: URL
        public let assetName: String
        /// `sha256:<hex>` digest GitHub reports for the asset, when present.
        public let sha256: String?
    }

    /// Picks the macOS ZIP for this machine (`-macos-<arch>.zip`, else `-macos-universal.zip`).
    public static func parse(_ data: Data, arch: String) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let tag = object["tag_name"] as? String, let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = object["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        func asset(_ suffix: String) -> [String: Any]? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true && ($0["name"] as? String)?.hasPrefix("QuotaPilot-") == true }
        }
        guard let chosen = asset("-macos-\(arch).zip") ?? asset("-macos-universal.zip"),
              let name = chosen["name"] as? String,
              let link = (chosen["browser_download_url"] as? String).flatMap(URL.init(string:)),
              link.scheme == "https", link.host == "github.com" || link.host?.hasSuffix(".githubusercontent.com") == true else { return nil }
        let digest = (chosen["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return Release(version: version, pageURL: page, assetURL: link, assetName: name, sha256: digest)
    }

    /// Numeric comparison of dotted versions; `0.10.0` is newer than `0.9.2`. Anything after `+` or `-` is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.split(whereSeparator: { $0 == "+" || $0 == "-" }).first.map(String.init) ?? v
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Sends `quotapilot share` reports without a browser by filing the issue with the GitHub CLI (`gh`),
/// which the user has already signed in to. Nothing is sent unless the user turned sharing on.
public enum ShareSubmitter {
    public static let defaultRepo = "dwagwd/quotapilot"

    public static func ghPath(home: URL, environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        var candidates = (environmentPath ?? "").split(separator: ":").map { String($0) + "/gh" }
        candidates += ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", home.appendingPathComponent(".local/bin/gh").path, "/usr/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Files one issue. Returns the issue URL, or an error message.
    public static func submit(title: String, body: String, repo: String = defaultRepo, gh: String) -> Result<String, Error> {
        let process = Process(), output = Pipe(), errors = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["issue", "create", "--repo", repo, "--title", title, "--body-file", "-"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { return .failure(error) }
        input.fileHandleForWriting.write(Data(body.utf8)); try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile(), err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failure(NSError(domain: "ShareSubmitter", code: Int(process.terminationStatus),
                                    userInfo: [NSLocalizedDescriptionKey: String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)]))
        }
        return .success(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
