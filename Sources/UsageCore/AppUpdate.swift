import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Finds a newer QuotaPilot release on GitHub. Pure parsing and comparison; the app does the network call,
/// the download and the signature checks.
public enum AppUpdate {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/dwagwd/quotapilot/releases/latest")!
    /// Developer ID team that signs official builds. An update signed by anyone else is refused.
    /// Empty while no signed builds are published (QuotaPilot is built from source by Homebrew), so the
    /// in-app downloader can never install anything.
    public static let teamID = ""
    /// Version tags, for source installs: a newer tag means `brew upgrade quotapilot` has something to do.
    public static let tagsURL = URL(string: "https://api.github.com/repos/dwagwd/quotapilot/tags?per_page=100")!

    /// The highest safe `vX.Y.Z` tag in a GitHub tags listing.
    public static func newestTag(_ data: Data) -> String? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { $0["name"] as? String }
            .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            .filter { isSafeVersion($0) && !$0.contains("-") }
            .reduce(nil as String?) { best, v in best.map { isNewer(v, than: $0) ? v : $0 } ?? v }
    }
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
        // Both strings become path components under ~/Library/Caches and the version folder is removed before any
        // signature check, so a tag or asset name with "/" or ".." must never get that far.
        guard isSafeVersion(version) else { return nil }
        func asset(_ suffix: String) -> [String: Any]? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true && ($0["name"] as? String)?.hasPrefix("QuotaPilot-") == true }
        }
        guard let chosen = asset("-macos-\(arch).zip") ?? asset("-macos-universal.zip"),
              let name = chosen["name"] as? String, isSafeAssetName(name),
              let link = (chosen["browser_download_url"] as? String).flatMap(URL.init(string:)),
              link.scheme == "https", link.host == "github.com" || link.host?.hasSuffix(".githubusercontent.com") == true else { return nil }
        let digest = (chosen["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return Release(version: version, pageURL: page, assetURL: link, assetName: name, sha256: digest)
    }

    /// `1.2.3`, optionally followed by `-pre.1` or `+build`: digits, dots and a short ASCII suffix only.
    public static func isSafeVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]+(\.[0-9]+){0,3}([-+][A-Za-z0-9.]{1,32})?$"#, options: .regularExpression) != nil
    }

    /// `QuotaPilot-<something>.zip` built from file-name-safe ASCII; no separators, no `..`.
    public static func isSafeAssetName(_ name: String) -> Bool {
        name.count <= 128 && !name.contains("..")
            && name.range(of: #"^QuotaPilot-[A-Za-z0-9._-]+\.zip$"#, options: .regularExpression) != nil
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
    /// Anonymous collector (Cloudflare Worker in `collector/`). Override with QUOTAPILOT_COLLECTOR_URL.
    public static var collectorURL: URL {
        URL(string: ProcessInfo.processInfo.environment["QUOTAPILOT_COLLECTOR_URL"] ?? "https://aiquotawatch.pages.dev/api")!
    }

    /// A random id for this computer, created on first use and stored locally. The collector only keeps a
    /// keyed hash of it, so reports from one computer can be counted once a day without knowing who sent them.
    public static func installID(directory: URL = Portable.stateDirectory()) -> String {
        let file = directory.appendingPathComponent("install-id")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 16, saved.count <= 64 { return saved }
        let id = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: file, options: .atomic)
        return id
    }

    public static func anonymousBody(reports: [[String: Any]], install: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["install": install, "reports": reports])
    }

    /// Sends the reports to the anonymous collector. No GitHub account or login is involved.
    public static func postAnonymous(reports: [[String: Any]], install: String = installID(), url: URL = collectorURL, timeout: Double = 30) -> Result<Int, Error> {
        guard let body = anonymousBody(reports: reports, install: install) else {
            return .failure(NSError(domain: "ShareSubmitter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not encode the report."]))
        }
        var request = URLRequest(url: url.appendingPathComponent("v1/report"), timeoutInterval: timeout)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let done = DispatchSemaphore(value: 0)
        var result: Result<Int, Error> = .failure(NSError(domain: "ShareSubmitter", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response from the collector."]))
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = .success((object["accepted"] as? Int) ?? 0)
            } else {
                let message = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
                result = .failure(NSError(domain: "ShareSubmitter", code: status, userInfo: [NSLocalizedDescriptionKey: message ?? error?.localizedDescription ?? "HTTP \(status)"]))
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 5)
        return result
    }

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
