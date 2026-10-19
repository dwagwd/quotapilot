import AppKit
import Charts
import SwiftUI
import UsageCore

/// Snapshot of the statistics handed to the SwiftUI view; refreshed by the app delegate.
final class StatsModel: ObservableObject {
    @Published var store = UsageStatsStore()
    @Published var language: WidgetLanguage = .system
    @Published var backfilling = false
}

enum StatsRange: String, CaseIterable, Identifiable {
    case day = "24h", week = "7d", month = "30d"
    var id: String { rawValue }
    var seconds: Double { self == .day ? 86400 : self == .week ? 7 * 86400 : 30 * 86400 }
    var bucket: Double { self == .month ? 86400 : self == .week ? 6 * 3600 : 3600 }
}

struct StatsView: View {
    @ObservedObject var model: StatsModel
    @State private var range: StatsRange = .week
    private var l: L10n { L10n(model.language) }

    private func providerName(_ id: String) -> String {
        ["codex": "Codex", "claude": "Claude", "deepseek": "DeepSeek", "kimi": "Kimi", "glm": "GLM", "qwen": "Qwen",
         "minimax": "MiniMax", "gemini": "Gemini", "gpt": "GPT"][id] ?? id
    }

    var body: some View {
        let now = Date().timeIntervalSince1970
        let since = now - range.seconds
        let totals = model.store.tokenTotals(since: since, now: now)
        let all = totals.values.reduce(into: TokenBreakdown()) { $0.add($1) }
        let hours = range.seconds / 3600
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("", selection: $range) { ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 220)
                    Spacer()
                    if model.backfilling { ProgressView().controlSize(.small); Text(l.text("statsBackfilling")).font(.caption).foregroundStyle(.secondary) }
                }
                GroupBox(l.text("statsTokens")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l.text("tokenTotal") + " " + l.compact(all.total) + "  ·  ≈" + l.compact(all.total / hours) + "/" + l.unit(.hour, short: true))
                            .font(.headline)
                        Text(breakdown(all)).font(.caption).foregroundStyle(.secondary)
                        ForEach(totals.sorted { $0.value.total > $1.value.total }, id: \.key) { provider, usage in
                            Text(providerName(provider) + "  " + l.compact(usage.total) + "  —  " + breakdown(usage)).font(.caption)
                        }
                        Chart {
                            ForEach(Array(model.store.tokenSeries(since: since, now: now, bucket: range.bucket).enumerated()), id: \.offset) { _, point in
                                LineMark(x: .value("Time", Date(timeIntervalSince1970: point.start)),
                                         y: .value("Tokens", point.tokens))
                                    .foregroundStyle(by: .value("Provider", providerName(point.provider)))
                                    .interpolationMethod(.monotone)
                            }
                        }
                        .chartYAxis { AxisMarks { value in
                            AxisGridLine(); AxisValueLabel { Text(l.compact(value.as(Double.self) ?? 0)) }
                        } }
                        .frame(height: 180)
                    }.padding(4)
                }
                GroupBox(l.text("outputSpeed") + " (tok/s)") {
                    VStack(alignment: .leading, spacing: 6) {
                        let speeds = model.store.outputSpeed(since: since, now: now)
                        if speeds.isEmpty {
                            Text(l.text("collecting")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(speeds.sorted { $0.key < $1.key }.map { providerName($0.key) + " ≈" + l.number($0.value.tokensPerSecond, decimals: 0) + " tok/s" }.joined(separator: "  ·  "))
                                .font(.headline)
                        }
                        Chart {
                            ForEach(Array(model.store.speedSeries(since: since, now: now, bucket: range.bucket).enumerated()), id: \.offset) { _, point in
                                LineMark(x: .value("Time", Date(timeIntervalSince1970: point.start)), y: .value("tok/s", point.tokens))
                                    .foregroundStyle(by: .value("Provider", providerName(point.provider)))
                                    .interpolationMethod(.monotone)
                            }
                        }
                        .frame(height: 140)
                        Text(l.text("outputSpeedHelp")).font(.caption2).foregroundStyle(.secondary)
                    }.padding(4)
                }
                GroupBox(l.text("statsQuota")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.store.quotaWindowIDs, id: \.self) { id in
                            let title = model.store.windowTitles[id] ?? id
                            if let rate = model.store.quotaConsumptionPerHour(windowID: id, since: since) {
                                Text(title + "  ·  ≈" + l.number(rate.perHour, decimals: 2) + " " + l.text("points") + "/" + l.unit(.hour, short: true)
                                     + "  ·  " + l.number(rate.consumed, decimals: 0) + " " + l.text("points") + " / " + l.number(rate.hours, decimals: 0) + " " + l.unit(.hour, short: true))
                                    .font(.caption)
                            } else {
                                Text(title + "  ·  " + l.text("collecting")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Chart {
                            ForEach(model.store.quotaWindowIDs, id: \.self) { id in
                                ForEach(model.store.quotaSeries(windowID: id, since: since), id: \.t) { sample in
                                    LineMark(x: .value("Time", Date(timeIntervalSince1970: sample.t)), y: .value("Used %", sample.used))
                                        .foregroundStyle(by: .value("Window", model.store.windowTitles[id] ?? id))
                                }
                            }
                        }
                        .chartYScale(domain: 0...100)
                        .frame(height: 180)
                        Text(l.text("statsQuotaHelp")).font(.caption2).foregroundStyle(.secondary)
                    }.padding(4)
                }
            }.padding(14)
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    private func breakdown(_ b: TokenBreakdown) -> String {
        [l.text("tokenInput") + " " + l.compact(b.input), l.text("tokenCacheRead") + " " + l.compact(b.cacheRead),
         l.text("tokenCacheWrite") + " " + l.compact(b.cacheWrite),
         l.text("tokenOutput") + " " + l.compact(b.output) + (b.reasoning > 0 ? " (" + l.text("tokenReasoning") + " " + l.compact(b.reasoning) + ")" : "")]
            .joined(separator: " · ")
    }
}

final class StatsWindowController: NSWindowController {
    init(model: StatsModel, title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StatsView(model: model))
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func present() { showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
}
