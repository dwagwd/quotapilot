import AppKit
import CryptoKit
import UsageCore

/// Checks GitHub for a newer release and installs it in place after the user confirms.
/// The download must match GitHub's SHA-256 digest (when published), pass `codesign --verify --deep --strict`,
/// be signed by QuotaPilot's Developer ID team, and pass Gatekeeper (notarized) before anything is replaced.
final class AppUpdater {
    enum Failure: Error { case download, digest, unzip, signature(String), location }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private(set) var available: AppUpdate.Release?
    private var checking = false

    private var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Fetches the latest release; calls back on the main queue with a newer release, or nil.
    func check(completion: @escaping (AppUpdate.Release?) -> Void) {
        guard !checking else { return }
        checking = true
        var request = URLRequest(url: AppUpdate.latestReleaseURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200
            let release = ok ? data.flatMap { AppUpdate.parse($0, arch: self?.arch ?? "arm64") } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.available = release.flatMap { AppUpdate.isNewer($0.version, than: self.currentVersion) ? $0 : nil }
                completion(self.available)
            }
        }.resume()
    }

    /// Downloads, verifies and stages the update, then quits; a small helper swaps the app and reopens it.
    func install(_ release: AppUpdate.Release, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.stage(release) }
            DispatchQueue.main.async {
                switch result {
                case .success(let staged):
                    self.swapAndRelaunch(staged)
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func stage(_ release: AppUpdate.Release) throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("QuotaPilot/update/\(release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let done = DispatchSemaphore(value: 0)
        var downloaded: Data?
        URLSession.shared.dataTask(with: URLRequest(url: release.assetURL, timeoutInterval: 300)) { data, response, _ in
            if ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200 { downloaded = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 320)
        guard let zip = downloaded, !zip.isEmpty else { throw Failure.download }
        if let expected = release.sha256 {
            let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw Failure.digest }
        }
        let zipURL = folder.appendingPathComponent(release.assetName)
        try zip.write(to: zipURL)
        guard run("/usr/bin/ditto", ["-x", "-k", zipURL.path, folder.path]).status == 0 else { throw Failure.unzip }
        let app = folder.appendingPathComponent("QuotaPilot.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw Failure.unzip }

        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else { throw Failure.signature("codesign: " + verify.output) }
        let info = run("/usr/bin/codesign", ["-dv", app.path])
        guard info.output.contains("TeamIdentifier=\(AppUpdate.teamID)") else { throw Failure.signature("unexpected signer") }
        let gatekeeper = run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard gatekeeper.status == 0 else { throw Failure.signature("Gatekeeper: " + gatekeeper.output) }

        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app", FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw Failure.location
        }
        return app
    }

    /// The helper waits for this process to exit, moves the old app aside, copies the new one in,
    /// restores the old one if the copy fails, and opens the result. Paths are passed as arguments, not
    /// pasted into the script.
    private func swapAndRelaunch(_ staged: URL) {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.5; done
        backup="$2.previous"
        /bin/rm -rf "$backup"
        if /bin/mv "$2" "$backup" && /usr/bin/ditto "$3" "$2"; then /bin/rm -rf "$backup"; else /bin/rm -rf "$2"; /bin/mv "$backup" "$2"; fi
        /usr/bin/open "$2"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "quotapilot-update", String(ProcessInfo.processInfo.processIdentifier),
                            Bundle.main.bundleURL.path, staged.path]
        try? helper.run()
        NSApp.terminate(nil)
    }
}
