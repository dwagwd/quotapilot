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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                tokenSection(since: since, now: now)
                speedSection(since: since, now: now)
                quotaSection(since: since)
            }.padding(14)
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    // Split into sections: one large body expression exceeds the type checker's time limit on older compilers.
    private var header: some View {
        HStack {
            Picker("", selection: $range) { ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 220)
            Spacer()
            if model.backfilling { ProgressView().controlSize(.small); Text(l.text("statsBackfilling")).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func tokenHeadline(_ all: TokenBreakdown) -> String {
        let hours = range.seconds / 3600
        return l.text("tokenTotal") + " " + l.compact(all.total) + "  ·  ≈" + l.compact(all.total / hours) + "/" + l.unit(.hour, short: true)
    }

    private func tokenSection(since: Double, now: Double) -> some View {
        let totals = model.store.tokenTotals(since: since, now: now)
        let all = totals.values.reduce(into: TokenBreakdown()) { $0.add($1) }
        let rows: [(key: String, value: TokenBreakdown)] = totals.sorted { $0.value.total > $1.value.total }
        let series: [TokenSeriesPoint] = model.store.tokenSeries(since: since, now: now, bucket: range.bucket)
        return GroupBox(l.text("statsTokens")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tokenHeadline(all)).font(.headline)
                Text(breakdown(all)).font(.caption).foregroundStyle(.secondary)
                ForEach(rows, id: \.key) { row in
                    Text(providerName(row.key) + "  " + l.compact(row.value.total) + "  —  " + breakdown(row.value)).font(.caption)
                }
                seriesChart(series, label: "Tokens")
                    .chartYAxis { AxisMarks { value in
                        AxisGridLine(); AxisValueLabel { Text(l.compact(value.as(Double.self) ?? 0)) }
                    } }
                    .frame(height: 180)
            }.padding(4)
        }
    }

    private func seriesChart(_ points: [TokenSeriesPoint], label: String) -> some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", Date(timeIntervalSince1970: point.start)), y: .value(label, point.tokens))
                    .foregroundStyle(by: .value("Provider", providerName(point.provider)))
                    .interpolationMethod(.monotone)
            }
        }
    }

    private func speedHeadline(_ speeds: [String: (tokensPerSecond: Double, outputTokens: Double, seconds: Double)]) -> String {
        speeds.sorted { $0.key < $1.key }
            .map { providerName($0.key) + " ≈" + l.number($0.value.tokensPerSecond, decimals: 0) + " tok/s" }
            .joined(separator: "  ·  ")
    }

    private func speedSection(since: Double, now: Double) -> some View {
        let speeds = model.store.outputSpeed(since: since, now: now)
        let series: [TokenSeriesPoint] = model.store.speedSeries(since: since, now: now, bucket: range.bucket)
        return GroupBox(l.text("outputSpeed") + " (tok/s)") {
            VStack(alignment: .leading, spacing: 6) {
                if speeds.isEmpty {
                    Text(l.text("collecting")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(speedHeadline(speeds)).font(.headline)
                }
                seriesChart(series, label: "tok/s").frame(height: 140)
                Text(l.text("outputSpeedHelp")).font(.caption2).foregroundStyle(.secondary)
            }.padding(4)
        }
    }

    private func quotaLine(_ id: String, since: Double) -> Text {
        let title = model.store.windowTitles[id] ?? id
        guard let rate = model.store.quotaConsumptionPerHour(windowID: id, since: since) else {
            return Text(title + "  ·  " + l.text("collecting")).font(.caption).foregroundColor(.secondary)
        }
        let hour = l.unit(.hour, short: true), points = l.text("points")
        let perHour = "≈" + l.number(rate.perHour, decimals: 2) + " " + points + "/" + hour
        let consumed = l.number(rate.consumed, decimals: 0) + " " + points + " / " + l.number(rate.hours, decimals: 0) + " " + hour
        return Text(title + "  ·  " + perHour + "  ·  " + consumed).font(.caption)
    }

    private func quotaChart(since: Double) -> some View {
        let ids = model.store.quotaWindowIDs
        return Chart {
            ForEach(ids, id: \.self) { id in
                ForEach(model.store.quotaSeries(windowID: id, since: since), id: \.t) { sample in
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: sample.t)), y: .value("Used %", sample.used))
                        .foregroundStyle(by: .value("Window", model.store.windowTitles[id] ?? id))
                }
            }
        }
        .chartYScale(domain: 0...100)
    }

    private func quotaSection(since: Double) -> some View {
        GroupBox(l.text("statsQuota")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.store.quotaWindowIDs, id: \.self) { id in quotaLine(id, since: since) }
                quotaChart(since: since).frame(height: 180)
                Text(l.text("statsQuotaHelp")).font(.caption2).foregroundStyle(.secondary)
            }.padding(4)
        }
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
