import Foundation

/// How quota rows are ordered on the card.
public enum QuotaSort: String, Codable, CaseIterable { case detected, mostUsed, resetSoonest, name }

/// Orders provider groups (each a list of windows). `pinned` providers come first in the given order;
/// the rest follow `sort`. Ties keep the detected order.
public func sortQuotaGroups(_ groups: [[WindowItem]], sort: QuotaSort, pinned: [String], now: Double) -> [[WindowItem]] {
    func provider(_ g: [WindowItem]) -> String { String(g.first?.id.split(separator: ":").first ?? "") }
    func maxUsed(_ g: [WindowItem]) -> Double { g.compactMap { $0.window.validUsedPercent }.max() ?? -1 }
    func nextReset(_ g: [WindowItem]) -> Double { g.compactMap { $0.window.resetsAt }.filter { $0 > now }.min() ?? .infinity }
    let indexed = Array(groups.enumerated())
    let ordered = indexed.sorted { a, b in
        let pa = pinned.firstIndex(of: provider(a.element)) ?? Int.max, pb = pinned.firstIndex(of: provider(b.element)) ?? Int.max
        if pa != pb { return pa < pb }
        switch sort {
        case .detected: break
        case .mostUsed: if maxUsed(a.element) != maxUsed(b.element) { return maxUsed(a.element) > maxUsed(b.element) }
        case .resetSoonest: if nextReset(a.element) != nextReset(b.element) { return nextReset(a.element) < nextReset(b.element) }
        case .name:
            let na = a.element.first?.name ?? "", nb = b.element.first?.name ?? ""
            if na != nb { return na.localizedCaseInsensitiveCompare(nb) == .orderedAscending }
        }
        return a.offset < b.offset
    }
    return ordered.map(\.element)
}
