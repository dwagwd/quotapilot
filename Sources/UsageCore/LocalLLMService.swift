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

    /// - Parameter omlxKey: supplies the oMLX API key (Keychain in the app, an environment variable in the CLI); read on each poll.
    /// - Parameters:
    ///   - llamaPorts: ports probed for llama.cpp (default: its documented ports)
    ///   - omlxPort: oMLX's port (default 8000)
    public init(log: LocalLLMLog, omlxKey: @escaping () -> String? = { ProcessInfo.processInfo.environment["QUOTAPILOT_OMLX_API_KEY"] },
                llamaPorts: [Int] = LocalLLMBackend.llamacpp.pollPorts, omlxPort: Int = LocalLLMBackend.omlx.defaultUpstreamPort) {
        self.log = log; self.omlxKey = omlxKey; self.llamaPorts = llamaPorts; self.omlxPort = omlxPort
    }

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
                lock.lock(); proxies[backend] = nil; lock.unlock()
            }
            lock.lock(); proxyErrors[backend] = nil; lock.unlock()
            if !settings.polls(backend) { lock.lock(); pollStates[backend] = .off; lock.unlock() }
            guard wanted else { continue }
            let proxy = LocalMeteringProxy(backend: backend, listenPort: settings.listenPort(backend), upstreamHost: settings.upstreamHost(backend),
                                           upstreamPort: settings.upstreamPort(backend)) { [weak self] event in self?.record([event]) }
            do { try proxy.start(); lock.lock(); proxies[backend] = proxy; lock.unlock() }
            catch { lock.lock(); proxyErrors[backend] = "\(error)"; lock.unlock() }
        }
        if !settings.polls(.llamacpp) { llamaDiffer = LlamaMetricsDiffer(); llamaPort = nil }
        if !settings.polls(.omlx) { omlxDiffer = OMLXUsageDiffer() }
    }

    public func stop() {
        lock.lock(); let all = Array(proxies.values); proxies = [:]; lock.unlock()
        all.forEach { $0.stop() }
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
        if settings.polls(.llamacpp) { events += pollLlama(now: now) }
        if settings.polls(.omlx) { events += pollOMLX(now: now) }
        if !events.isEmpty { record(events) }
        return events
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
