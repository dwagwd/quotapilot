import Foundation

/// Reading of one backend's poll for the settings window and `quotapilot local status`.
public enum LocalPollState: Equatable {
    case off
    /// Nothing answers on the backend's ports.
    case notRunning
    /// llama.cpp answers but `/metrics` is disabled (start it with `--metrics`) or is a router that needs `?model=`.
    case metricsUnavailable
    /// oMLX answered 401.
    case needsKey
    /// oMLX answered but not with usage data.
    case unsupported
    /// Another QuotaPilot process (for example `quotapilot local proxy`) already meters this backend through its proxy.
    case proxiedElsewhere
    /// Another QuotaPilot process (the app or `quotapilot local poll`) is polling.
    case otherProcess
    case ok(port: Int)
}

/// Runs the pollers and the proxies for the current settings. Events go to the log and to `onEvents`.
/// The owner calls `apply` when settings change and `pollOnce` on a timer of at least 60 seconds.
public final class LocalLLMService {
    public let log: LocalLLMLog
    public var onEvents: (([LocalLLMEvent]) -> Void)?
    private let lock = NSLock()
    private var settings = LocalLLMSettings()
    private var proxies: [LocalLLMBackend: LocalMeteringProxy] = [:]
    private var proxyErrors: [LocalLLMBackend: String] = [:]
    private var pollStates: [LocalLLMBackend: LocalPollState] = [:]
    private var llamaDiffer = LlamaMetricsDiffer()
    private var omlxDiffer = OMLXUsageDiffer()
    private var llamaPort: Int?
    private let omlxKey: () -> String?
    private let llamaPorts: [Int]
    private let omlxPort: Int
    /// Folder for the lock files that keep several QuotaPilot processes (app and CLI) from metering the same backend twice; nil: none.
    private let lockDirectory: URL?
    private var proxyLocks: [LocalLLMBackend: ProcessLock] = [:]
    private lazy var pollLock: ProcessLock? = lockDirectory.map { ProcessLock(url: $0.appendingPathComponent("local-llm-poll.lock")) }

    /// - Parameter omlxKey: supplies the oMLX API key (Keychain in the app, an environment variable in the CLI); read on each poll.
    /// - Parameters:
    ///   - llamaPorts: ports probed for llama.cpp (default: its documented ports)
    ///   - omlxPort: oMLX's port (default 8000)
    public init(log: LocalLLMLog, omlxKey: @escaping () -> String? = { ProcessInfo.processInfo.environment["QUOTAPILOT_OMLX_API_KEY"] },
                llamaPorts: [Int] = LocalLLMBackend.llamacpp.pollPorts, omlxPort: Int = LocalLLMBackend.omlx.defaultUpstreamPort,
                lockDirectory: URL? = nil) {
        self.log = log; self.omlxKey = omlxKey; self.llamaPorts = llamaPorts; self.omlxPort = omlxPort; self.lockDirectory = lockDirectory
    }

    private func proxyLockURL(_ backend: LocalLLMBackend) -> URL? { lockDirectory?.appendingPathComponent("local-llm-proxy-\(backend.rawValue).lock") }

    /// Takes the poll lock (once per process). False when another QuotaPilot process polls.
    public func acquirePollLock() -> Bool { pollLock?.tryAcquire() ?? true }

    public func pollState(_ backend: LocalLLMBackend) -> LocalPollState { lock.lock(); defer { lock.unlock() }; return pollStates[backend] ?? .off }
    public func proxyError(_ backend: LocalLLMBackend) -> String? { lock.lock(); defer { lock.unlock() }; return proxyErrors[backend] }
    public func proxyRunning(_ backend: LocalLLMBackend) -> Bool { lock.lock(); defer { lock.unlock() }; return proxies[backend]?.isRunning ?? false }

    /// Starts and stops proxies to match `settings`.
    public func apply(_ settings: LocalLLMSettings) {
        lock.lock(); self.settings = settings; lock.unlock()
        for backend in LocalLLMBackend.allCases {
            let wanted = settings.isEnabled && settings.proxyEnabled(backend)
            lock.lock(); let existing = proxies[backend]; lock.unlock()
            if let existing {
                let same = existing.port == settings.listenPort(backend) && existing.upstreamPort == settings.upstreamPort(backend)
                    && existing.upstreamHost == settings.upstreamHost(backend)
                if wanted && same && existing.isRunning { continue }
                existing.stop()
                lock.lock(); proxies[backend] = nil; proxyLocks[backend]?.release(); proxyLocks[backend] = nil; lock.unlock()
            }
            lock.lock(); proxyErrors[backend] = nil; lock.unlock()
            if !settings.polls(backend) { lock.lock(); pollStates[backend] = .off; lock.unlock() }
            guard wanted else { continue }
            let proxy = LocalMeteringProxy(backend: backend, listenPort: settings.listenPort(backend), upstreamHost: settings.upstreamHost(backend),
                                           upstreamPort: settings.upstreamPort(backend)) { [weak self] event in self?.record([event]) }
            do {
                try proxy.start()
                // Shared: any number of proxies may hold it; a poller elsewhere sees that this backend is metered by a proxy.
                let marker = proxyLockURL(backend).map { ProcessLock(url: $0) }
                _ = marker?.tryAcquire(shared: true)
                lock.lock(); proxies[backend] = proxy; proxyLocks[backend] = marker; lock.unlock()
            }
            catch { lock.lock(); proxyErrors[backend] = "\(error)"; lock.unlock() }
        }
        if !settings.polls(.llamacpp) { llamaDiffer = LlamaMetricsDiffer(); llamaPort = nil }
        if !settings.polls(.omlx) { omlxDiffer = OMLXUsageDiffer() }
        if !LocalLLMBackend.allCases.contains(where: settings.polls) { pollLock?.release() }
    }

    public func stop() {
        lock.lock(); let all = Array(proxies.values); proxies = [:]; let locks = Array(proxyLocks.values); proxyLocks = [:]; lock.unlock()
        all.forEach { $0.stop() }
        locks.forEach { $0.release() }
        pollLock?.release()
    }

    private func record(_ events: [LocalLLMEvent]) {
        log.append(events)
        onEvents?(events)
    }

    /// One round of polling for every backend whose poller is on. Cheap: a refused connection costs nothing, an answering port two short requests.
    @discardableResult
    public func pollOnce(now: Double = Date().timeIntervalSince1970) -> [LocalLLMEvent] {
        lock.lock(); let settings = self.settings; lock.unlock()
        var events: [LocalLLMEvent] = []
        let wanted = [LocalLLMBackend.llamacpp, .omlx].filter(settings.polls)
        if !wanted.isEmpty, !acquirePollLock() {
            for backend in wanted { setState(backend, .otherProcess) }
            return []
        }
        for backend in wanted {
            if let url = proxyLockURL(backend), ProcessLock.isHeldElsewhere(url) { setState(backend, .proxiedElsewhere); continue }
            events += backend == .llamacpp ? pollLlama(now: now) : pollOMLX(now: now)
        }
        if !events.isEmpty { record(events) }
        return events
    }

    /// One look at what the pollers would see, for `quotapilot local status`: no proxy is started, no lock taken, nothing recorded.
    public func probe() -> [LocalLLMBackend: LocalPollState] {
        _ = pollLlama(now: Date().timeIntervalSince1970)
        _ = pollOMLX(now: Date().timeIntervalSince1970)
        return [.llamacpp: pollState(.llamacpp), .omlx: pollState(.omlx)]
    }

    private func setState(_ backend: LocalLLMBackend, _ state: LocalPollState) { lock.lock(); pollStates[backend] = state; lock.unlock() }

    private func pollLlama(now: Double) -> [LocalLLMEvent] {
        let ports = (llamaPort.map { [$0] } ?? []) + llamaPorts.filter { $0 != llamaPort }
        var sawPort = false
        for port in ports where LocalHTTP.portAnswers(port: port) {
            sawPort = true
            guard let response = LocalHTTP.get(port: port, path: "/metrics", timeout: 1.5),
                  response.status == 200, let text = String(data: response.body, encoding: .utf8),
                  let reading = LlamaMetricsReading(prometheus: text) else { continue }
            if llamaPort != port { llamaDiffer = LlamaMetricsDiffer(); llamaPort = port }
            setState(.llamacpp, .ok(port: port))
            let model = llamaModel(port: port)
            return llamaDiffer.step(reading, model: model, now: now).map { [$0] } ?? []
        }
        setState(.llamacpp, sawPort ? .metricsUnavailable : .notRunning)
        return []
    }

    private func llamaModel(port: Int) -> String? {
        guard let response = LocalHTTP.get(port: port, path: "/v1/models", timeout: 1), response.status == 200,
              let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let data = object["data"] as? [[String: Any]], let id = data.first?["id"] as? String else { return nil }
        return String(id.prefix(160))
    }

    private func pollOMLX(now: Double) -> [LocalLLMEvent] {
        let port = omlxPort
        guard LocalHTTP.portAnswers(port: port) else { setState(.omlx, .notRunning); return [] }
        var headers: [String: String] = [:]
        if let key = omlxKey(), !key.isEmpty { headers["Authorization"] = "Bearer " + key }
        guard let response = LocalHTTP.get(port: port, path: "/admin/api/usage?range=today", headers: headers, timeout: 1.5) else {
            setState(.omlx, .unsupported); return []
        }
        if response.status == 401 || response.status == 403 { setState(.omlx, .needsKey); return [] }
        guard response.status == 200, let reading = OMLXUsageReading(json: response.body) else { setState(.omlx, .unsupported); return [] }
        setState(.omlx, .ok(port: port))
        return omlxDiffer.step(reading, now: now)
    }
}
