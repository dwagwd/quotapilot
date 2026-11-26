import AppKit
import SwiftUI
import UsageCore

/// State shown by the Local models window and the local section of the statistics window.
final class LocalModelsModel: ObservableObject {
    @Published var settings = LocalLLMSettings()
    @Published var language: WidgetLanguage = .system
    @Published var events: [LocalLLMEvent] = []
    @Published var detectedPort: [String: Int] = [:]
    @Published var pollStates: [String: LocalPollState] = [:]
    @Published var proxyErrors: [String: String] = [:]
    @Published var keySaved = false
    var onChange: ((LocalLLMSettings) -> Void)?
    var onSaveKey: ((String) -> Void)?
    var onRefresh: (() -> Void)?
}

/// Per model lines (requests, tokens, speeds, active time, hypothetical cloud cost) for events in `[since, ...)`.
struct LocalUsageLines: View {
    let events: [LocalLLMEvent]
    let reference: String?
    let l: L10n

    var body: some View {
        let report = LocalLLMReport(events: events, reference: reference)
        VStack(alignment: .leading, spacing: 4) {
            if report.isEmpty {
                Text(l.text("localEmpty")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(String(format: l.text("localEquivalent"), l.usd(report.costUSD), report.reference.id)).font(.title3.weight(.semibold))
                    .help(l.text("localReferenceHelp"))
                Text(l.text("localReferenceHelp")).font(.caption2).foregroundStyle(.secondary)
                ForEach(report.lines, id: \.id) { line in lineView(line) }
                if report.unmetered > 0 {
                    Text(String(format: l.text("localUnmetered"), l.compact(Double(report.unmetered)))).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private func lineView(_ line: LocalLLMReport.Line) -> some View {
        var parts = [line.requestsKnown ? String(format: l.text("localRequests"), l.compact(Double(line.requests))) : l.text("localRequestsUnknown"),
                     String(format: l.text("localInOut"), l.compact(line.prompt), l.compact(line.completion))]
        if line.cached > 0 { parts.append(String(format: l.text("localCached"), l.compact(line.cached))) }
        if let speed = line.promptTokensPerSecond { parts.append(String(format: l.text("localPromptSpeed"), l.number(speed, decimals: 0))) }
        if let speed = line.generationTokensPerSecond { parts.append(String(format: l.text("localGenSpeed"), l.number(speed, decimals: 0))) }
        if line.activeSeconds >= 1 { parts.append(String(format: l.text("statsActive"), l.activeTime(minutes: line.activeSeconds / 60))) }
        let name = (LocalLLMBackend(rawValue: line.backend)?.displayName ?? line.backend) + " · " + (line.model ?? l.text("statsUnknownModel"))
        return VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption.weight(.semibold))
            Text(parts.joined(separator: "  ·  ")).font(.caption2).foregroundStyle(.secondary)
                .help(line.proxyMeasuredSpeed ? l.text("localProxyMeasured") : "")
        }
    }
}

struct LocalModelsView: View {
    @ObservedObject var model: LocalModelsModel
    @State private var key = ""
    @State private var range: StatsRange = .week
    private var l: L10n { L10n(model.language) }

    private func binding<T>(_ get: @escaping (LocalLLMSettings) -> T, _ set: @escaping (inout LocalLLMSettings, T) -> Void) -> Binding<T> {
        Binding(get: { get(model.settings) }, set: { value in
            var next = model.settings; set(&next, value); model.settings = next; model.onChange?(next)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(l.text("localEnable"), isOn: binding({ $0.isEnabled }, { $0.enabled = $1 })).toggleStyle(.switch)
                Text(l.text("localEnableHelp")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(l.text("localReference")).font(.caption)
                    Picker("", selection: binding({ $0.reference }, { $0.referenceModel = $1 })) {
                        ForEach(LocalLLMReference.choices, id: \.id) { Text($0.id + "  ($" + String($0.input) + " / $" + String($0.output) + ")").tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 260)
                }
                Text(l.text("localReferenceHelp")).font(.caption2).foregroundStyle(.secondary)
                Divider()
                ForEach(LocalLLMBackend.allCases, id: \.rawValue) { backend in backendRow(backend) }
                Text(l.text("localProxyNote")).font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text(l.text("localKeyLabel")).font(.caption)
                    SecureField("", text: $key).frame(maxWidth: 200)
                    Button("OK") { model.onSaveKey?(key); key = ""; model.keySaved = true }.disabled(key.isEmpty)
                    if model.keySaved { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                }
                Divider()
                Picker("", selection: $range) { ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 220)
                LocalUsageLines(events: model.events.filter { $0.t >= Date().timeIntervalSince1970 - range.seconds },
                                reference: model.settings.referenceModel, l: l)
            }.padding(14)
        }.frame(minWidth: 540, minHeight: 560)
    }

    private func backendRow(_ backend: LocalLLMBackend) -> some View {
        let settings = model.settings
        let detected = model.detectedPort[backend.rawValue]
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(backend.displayName).font(.headline)
                Text(detected.map { String(format: l.text("localBackendRunning"), String($0)) } ?? l.text("localBackendAbsent"))
                    .font(.caption).foregroundStyle(detected == nil ? .secondary : Color.green)
            }
            Text(statusText(backend)).font(.caption2).foregroundStyle(.secondary)
            Toggle(l.text("localProxyToggle"), isOn: binding({ $0.proxyEnabled(backend) }, { settings, on in settings.update(backend) { $0.proxy = on } }))
                .font(.caption).disabled(!settings.isEnabled || !LocalSockets.isSupported)
            if settings.proxyEnabled(backend) {
                Text(String(format: l.text("localProxyURL"), settings.proxyURL(backend))).font(.caption).textSelection(.enabled)
                if let error = model.proxyErrors[backend.rawValue] {
                    Text(String(format: l.text("localProxyFailed"), error)).font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    private func statusText(_ backend: LocalLLMBackend) -> String {
        guard backend.hasPoller else { return l.text("localUsageNeedsProxy") }
        if model.settings.proxyEnabled(backend) { return l.text("localUsageNeedsProxy") }
        switch model.pollStates[backend.rawValue] ?? .off {
        case .metricsUnavailable: return l.text("localNeedsMetrics")
        case .needsKey: return l.text("localNeedsKey")
        default: return l.text("localUsageAuto")
        }
    }
}

final class LocalModelsWindowController: NSWindowController {
    init(model: LocalModelsModel, title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: LocalModelsView(model: model))
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func present() { showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
}
