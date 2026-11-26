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
    /// Everything of the last 30 days, for the monthly electricity figure.
    var monthEvents: [LocalLLMEvent] = []
    var energy = EnergySettings()

    var body: some View {
        let report = LocalLLMReport(events: events, reference: reference)
        VStack(alignment: .leading, spacing: 4) {
            if report.isEmpty {
                Text(l.text("localEmpty")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(String(format: l.text("localEquivalent"), l.usd(report.costUSD), report.reference.id)).font(.title3.weight(.semibold))
                    .help(l.text("localReferenceHelp"))
                Text(l.text("localReferenceHelp")).font(.caption2).foregroundStyle(.secondary)
                energyView
                ForEach(report.lines, id: \.id) { line in lineView(line) }
                if report.unmetered > 0 {
                    Text(String(format: l.text("localUnmetered"), l.compact(Double(report.unmetered)))).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    /// Electricity next to the hypothetical cloud cost; a prompt to enter the price while it is empty.
    @ViewBuilder
    private var energyView: some View {
        if !energy.hasPrice {
            Text(l.text("energyEmpty")).font(.caption).foregroundStyle(.secondary)
        } else {
            let result = LocalEnergyReport(events: events, reference: reference, settings: energy, locale: l.locale)
            if let cost = result.cost, !result.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: l.text("energyCost"), l.money(cost, currency: result.currency), l.inferenceTime(seconds: result.seconds), l.number(result.watts, decimals: 0)))
                        .font(.callout.weight(.semibold))
                    if let perMillion = result.costPerMillionTokens {
                        let cloud = result.cloudCostPerMillionTokens.map { l.money($0, currency: result.currency) } ?? l.usd(result.cloudPerMillionTokensUSD ?? 0)
                        Text(String(format: l.text("energyPerMillion"), l.money(perMillion, currency: result.currency), cloud)).font(.caption)
                    }
                    let month = LocalEnergyReport(events: monthEvents, reference: reference, settings: energy, locale: l.locale)
                    if let monthCost = month.cost, !month.isEmpty {
                        Text(String(format: l.text("energyMonth"), l.money(monthCost, currency: month.currency))).font(.caption)
                    }
                    Text(l.text("energyParallel")).font(.caption2).foregroundStyle(.secondary)
                    if result.cloudCost == nil { Text(l.text("energyNoRate")).font(.caption2).foregroundStyle(.secondary) }
                    if result.coverage < 0.95 { Text(String(format: l.text("energyCoverage"), l.percent(result.coverage))).font(.caption2).foregroundStyle(.orange) }
                    if energy.watts == nil {
                        Text(String(format: l.text("energyEstimate"), l.number(result.watts, decimals: 0), DevicePower.estimate(for: .current()).basis))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
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

/// Electricity price, currency, device power and optional exchange rate. Saved with the Save button.
struct EnergySettingsView: View {
    @ObservedObject var model: LocalModelsModel
    @State private var price = ""
    @State private var currency = ""
    @State private var watts = ""
    @State private var rate = ""
    @State private var loaded = false
    private var l: L10n { L10n(model.language) }

    private func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return trimmed.isEmpty ? nil : Double(trimmed)
    }
    private func show(_ value: Double?) -> String { value.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" }
    private func load() {
        let energy = model.settings.energySettings
        price = show(energy.pricePerKWh); currency = energy.currency ?? ""; watts = show(energy.watts); rate = show(energy.usdRate)
    }
    private var valid: Bool {
        EnergySettings.validate(price: number(price), watts: number(watts), rate: number(rate), currency: currency.isEmpty ? nil : currency.uppercased()) == nil
            && (price.isEmpty || number(price) != nil) && (watts.isEmpty || number(watts) != nil) && (rate.isEmpty || number(rate) != nil)
    }
    private func save() {
        var next = model.settings
        var energy = EnergySettings()
        energy.pricePerKWh = number(price).flatMap { $0 > 0 ? $0 : nil }
        energy.currency = currency.isEmpty ? nil : currency.uppercased()
        energy.watts = number(watts); energy.usdRate = number(rate)
        next.energySettings = energy
        model.settings = next; model.onChange?(next)
    }

    var body: some View {
        let energy = model.settings.energySettings
        let hardware = HardwareInfo.current()
        let typical = DevicePower.estimate(for: hardware)
        let systemCurrency = EnergySettings.systemCurrency(l.locale)
        VStack(alignment: .leading, spacing: 6) {
            Text(l.text("energyTitle")).font(.headline)
            HStack {
                Text(l.text("energyPrice")).font(.caption).frame(width: 200, alignment: .leading)
                TextField("", text: $price).frame(width: 80)
                TextField(systemCurrency, text: $currency).frame(width: 56)
            }
            HStack {
                Text(l.text("energyPower")).font(.caption).frame(width: 200, alignment: .leading)
                TextField(l.number(typical.watts, decimals: 0) + " (" + l.text("energyDefaultWatts") + ")", text: $watts).frame(width: 140)
            }
            if energy.resolvedCurrency(l.locale) != "USD" || !currency.isEmpty && currency.uppercased() != "USD" {
                HStack {
                    Text(l.text("energyRate")).font(.caption).frame(width: 200, alignment: .leading)
                    TextField("", text: $rate).frame(width: 80)
                    Text(currency.isEmpty ? systemCurrency : currency.uppercased()).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(l.text("localSave")) { save() }.disabled(!valid)
                if !valid { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Text(String(format: l.text("energyEstimate"), l.number(typical.watts, decimals: 0), typical.basis)).font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { if !loaded { load(); loaded = true } }
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
                    Button(l.text("localSave")) { model.onSaveKey?(key); key = ""; model.keySaved = true }.disabled(key.isEmpty)
                    if model.keySaved { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                }
                Divider()
                EnergySettingsView(model: model)
                Divider()
                Picker("", selection: $range) { ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 220)
                LocalUsageLines(events: model.events.filter { $0.t >= Date().timeIntervalSince1970 - range.seconds },
                                reference: model.settings.referenceModel, l: l,
                                monthEvents: model.events.filter { $0.t >= Date().timeIntervalSince1970 - 30 * 86400 },
                                energy: model.settings.energySettings)
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

/// Confirmation for sharing local model speeds. The preview is the raw JSON of every model; it scrolls in its own box
/// so many models cannot make the alert taller than the screen.
func localRunsAlert(l: L10n, preview: String) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = l.text("shareKind.localRuns")
    let marker = "\u{1}"
    let parts = String(format: l.text("localRunsExplain"), marker).components(separatedBy: marker)
    alert.informativeText = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let box = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
    box.hasVerticalScroller = true; box.borderType = .bezelBorder
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
    text.isEditable = false; text.isRichText = false; text.drawsBackground = false
    text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    text.textContainerInset = NSSize(width: 4, height: 4)
    text.isHorizontallyResizable = false; text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.string = preview
    box.documentView = text
    alert.accessoryView = box
    alert.addButton(withTitle: l.text("localRunsOn")); alert.addButton(withTitle: l.text("cancel"))
    return alert
}
