import AppKit
import CryptoKit
import UsageCore

/// Checks GitHub for a newer release, downloads it in the background with progress, verifies it, and
/// installs it in place when the user chooses to. A verified download is kept, so "Restart to update"
/// is instant. Before anything is replaced the download must match GitHub's SHA-256 digest (when
/// published), pass `codesign --verify --deep --strict`, be signed by QuotaPilot's Developer ID team,
/// and pass Gatekeeper (notarized).
final class AppUpdater: NSObject, URLSessionDownloadDelegate {
    enum Failure: Error, CustomStringConvertible {
        case download(String), digest, unzip, signature(String), location
        var description: String {
            switch self {
            case .download(let why): return "Download failed: \(why)"
            case .digest: return "The download does not match the published SHA-256 digest."
            case .unzip: return "The download could not be unpacked."
            case .signature(let why): return "The download failed verification: \(why)"
            case .location: return "QuotaPilot's folder is not writable, so it cannot replace itself. Install the new version from GitHub."
            }
        }
    }
    enum State: Equatable {
        case idle
        case available(AppUpdate.Release)
        case downloading(AppUpdate.Release, Double)
        case ready(AppUpdate.Release)
        case failed(AppUpdate.Release, String)
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private(set) var state: State = .idle { didSet { if state != oldValue { onChange?() } } }
    /// Called on the main queue whenever `state` changes (the menu uses it to show progress).
    var onChange: (() -> Void)?
    private var checking = false
    private var installAfterDownload = false
    private var attempts = 0
    private var stagedApp: URL?
    private var lastProgressStep = -1
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    var release: AppUpdate.Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .ready(let r), .failed(let r, _): return r
        case .idle: return nil
        }
    }

    private var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func folder(for release: AppUpdate.Release) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaPilot/update/\(release.version)", isDirectory: true)
    }

    // MARK: Check

    /// Fetches the latest release. With `prefetch`, a newer version starts downloading right away.
    func check(prefetch: Bool, completion: @escaping (AppUpdate.Release?) -> Void) {
        guard !checking else { return }
        checking = true
        var request = URLRequest(url: AppUpdate.latestReleaseURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                let latest = ok ? data.flatMap { AppUpdate.parse($0, arch: self.arch) } : nil
                guard let latest, AppUpdate.isNewer(latest.version, than: self.currentVersion) else {
                    if case .downloading = self.state {} else { self.state = .idle }
                    completion(nil); return
                }
                if self.release?.version != latest.version || { if case .failed = self.state { return true }; return false }() {
                    self.state = .available(latest)
                    self.reuseStagedDownload(latest)
                }
                if prefetch, case .available = self.state { self.download(install: false) }
                completion(latest)
            }
        }.resume()
    }

    /// A download verified in an earlier session is used again after a quick signature re-check.
    private func reuseStagedDownload(_ release: AppUpdate.Release) {
        let app = folder(for: release).appendingPathComponent("QuotaPilot.app")
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        DispatchQueue.global(qos: .utility).async {
            let ok = (try? self.verify(app)) != nil
            DispatchQueue.main.async {
                guard ok, self.release == release, case .available = self.state else { return }
                self.stagedApp = app; self.state = .ready(release)
            }
        }
    }

    // MARK: Download

    /// Starts (or joins) the download. With `install`, the app restarts into the new version once it is verified.
    func download(install: Bool) {
        installAfterDownload = installAfterDownload || install
        guard let release else { return }
        switch state {
        case .ready: if installAfterDownload { swapAndRelaunch() }; return
        case .downloading: return
        default: break
        }
        attempts = 0; lastProgressStep = -1
        startDownload(release)
    }

    private func startDownload(_ release: AppUpdate.Release) {
        attempts += 1
        state = .downloading(release, 0)
        session.downloadTask(with: URLRequest(url: release.assetURL, timeoutInterval: 120)).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let release, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let step = Int(fraction * 20)  // refresh the menu every 5%
        guard step != lastProgressStep else { return }
        lastProgressStep = step
        state = .downloading(release, fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let release else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let target = folder(for: release)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let zip = target.appendingPathComponent(release.assetName)
        // The temporary file is deleted when this method returns, so move it now.
        let moved = status == 200 && (try? FileManager.default.moveItem(at: location, to: zip)) != nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> URL in
                guard moved else { throw Failure.download("HTTP \(status)") }
                return try self.stage(zip: zip, release: release, in: target)
            }
            DispatchQueue.main.async { self.finished(release, result) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let release else { return }
        if attempts < 2 { startDownload(release); return }  // one retry for a dropped connection
        finished(release, .failure(Failure.download(error.localizedDescription)))
    }

    private func finished(_ release: AppUpdate.Release, _ result: Result<URL, Error>) {
        guard self.release == release else { return }
        switch result {
        case .success(let app):
            stagedApp = app; state = .ready(release)
            if installAfterDownload { swapAndRelaunch() }
        case .failure(let error):
            installAfterDownload = false
            state = .failed(release, String(describing: error))
        }
    }

    // MARK: Verify and install

    private func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stage(zip: URL, release: AppUpdate.Release, in folder: URL) throws -> URL {
        if let expected = release.sha256 { guard sha256(of: zip) == expected else { throw Failure.digest } }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]).status == 0 else { throw Failure.unzip }
        try? FileManager.default.removeItem(at: zip)
        let app = folder.appendingPathComponent("QuotaPilot.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw Failure.unzip }
        try verify(app)
        return app
    }

    private func verify(_ app: URL) throws {
        let check = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard check.status == 0 else { throw Failure.signature("codesign: " + check.output) }
        guard run("/usr/bin/codesign", ["-dv", app.path]).output.contains("TeamIdentifier=\(AppUpdate.teamID)") else {
            throw Failure.signature("not signed by the QuotaPilot team")
        }
        let gatekeeper = run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard gatekeeper.status == 0 else { throw Failure.signature("Gatekeeper: " + gatekeeper.output) }
    }

    /// The helper (`AppUpdate.swapScript`) waits for this process to exit, moves the old app aside, copies the
    /// new one in, restores the old one only if a backup was made, and opens the result. Paths are passed as arguments,
    /// not pasted into the script.
    func swapAndRelaunch() {
        guard let staged = stagedApp, let release else { return }
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app", FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            installAfterDownload = false
            state = .failed(release, Failure.location.description); return
        }
        UserDefaults.standard.set(release.version, forKey: "updatedTo")
        let script = AppUpdate.swapScript
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "quotapilot-update", String(ProcessInfo.processInfo.processIdentifier),
                            current.path, staged.path, staged.deletingLastPathComponent().path]
        try? helper.run()
        NSApp.terminate(nil)
    }
}
