import Foundation

/// Linear projection of an observed quota rate until the backend-reported reset.
/// It extrapolates the recent pace only; it is not a prediction of future work.
public struct QuotaForecast: Equatable {
    public enum Outlook: String, Codable { case onTrack, tight, exhausts }
    /// Projected used percentage at the reset time, capped at 100.
    public let projectedUsedAtReset: Double
    /// When the window reaches 100% at the observed pace, if that happens before the reset.
    public let exhaustsAt: Double?
    public var outlook: Outlook {
        if exhaustsAt != nil { return .exhausts }
        return projectedUsedAtReset >= quotaForecastTightThreshold ? .tight : .onTrack
    }
}

public let quotaForecastTightThreshold: Double = 90

public func forecastQuota(used: Double?, perHour: Double?, resetsAt: Double?, now: Double) -> QuotaForecast? {
    guard let used, used.isFinite, (0...100).contains(used),
          let perHour, perHour.isFinite, perHour >= 0,
          let resetsAt, resetsAt.isFinite, now.isFinite, resetsAt > now else { return nil }
    if used >= 100 { return QuotaForecast(projectedUsedAtReset: 100, exhaustsAt: now) }
    let projected = used + perHour * (resetsAt - now) / 3600
    guard projected >= 100, perHour > 0 else { return QuotaForecast(projectedUsedAtReset: projected, exhaustsAt: nil) }
    return QuotaForecast(projectedUsedAtReset: 100, exhaustsAt: now + (100 - used) / perHour * 3600)
}

public enum QuotaAlertKind: String, Codable, CaseIterable { case projectedExhaustion, highUsage }
public let quotaAlertHighUsageThreshold: Double = 90

/// Decides which quota alerts to send, at most once per kind for each window reset cycle.
/// A changed reset time or a drop in usage starts a new cycle.
public struct QuotaAlertTracker {
    private struct Cycle { var reset: Double?; var lastUsed: Double; var sent: Set<QuotaAlertKind> }
    private var cycles: [String: Cycle] = [:]
    public init() {}
    public mutating func alerts(windowID: String, used: Double?, resetsAt: Double?, forecast: QuotaForecast?) -> [QuotaAlertKind] {
        guard let used, used.isFinite, (0...100).contains(used) else { return [] }
        var cycle = cycles[windowID] ?? Cycle(reset: resetsAt, lastUsed: used, sent: [])
        if !sameReset(cycle.reset, resetsAt) || used < cycle.lastUsed { cycle = Cycle(reset: resetsAt, lastUsed: used, sent: []) }
        cycle.lastUsed = used
        var due: [QuotaAlertKind] = []
        if used >= quotaAlertHighUsageThreshold { due.append(.highUsage) }
        else if forecast?.outlook == .exhausts { due.append(.projectedExhaustion) }
        let fresh = due.filter { !cycle.sent.contains($0) }
        cycle.sent.formUnion(fresh)
        cycles[windowID] = cycle
        return fresh
    }
}

let forecastTranslations: [String: [String: String]] = [
    "paceForecast": ["en": "Pace forecast", "zh-Hant": "速度預估", "zh-Hans": "速度预估", "ja": "ペース予測", "ko": "속도 예측", "es": "Previsión de ritmo", "fr": "Prévision du rythme", "de": "Tempoprognose", "pt-BR": "Previsão de ritmo", "it": "Previsione del ritmo"],
    "forecastAtReset": ["en": "at reset", "zh-Hant": "於重置時", "zh-Hans": "于重置时", "ja": "リセット時", "ko": "재설정 시", "es": "al reiniciar", "fr": "à la réinitialisation", "de": "beim Zurücksetzen", "pt-BR": "na redefinição", "it": "al ripristino"],
    "forecastFullIn": ["en": "100% in", "zh-Hant": "達 100% 尚餘", "zh-Hans": "达 100% 还剩", "ja": "100% まで", "ko": "100%까지", "es": "100% en", "fr": "100% dans", "de": "100% in", "pt-BR": "100% em", "it": "100% tra"],
    "forecastHelp": ["en": "Linear projection of the observed rate until the reported reset time. It is not a promise of future usage.", "zh-Hant": "以觀測速度線性外推至回報的重置時間，並非未來用量的保證。", "zh-Hans": "以观测速度线性外推至报告的重置时间，并非未来用量的保证。", "ja": "観測した速度を報告されたリセット時刻まで直線的に延長した推定です。将来の使用量を保証するものではありません。", "ko": "관측된 속도를 보고된 재설정 시각까지 선형으로 연장한 추정치이며, 향후 사용량을 보장하지 않습니다.", "es": "Proyección lineal del ritmo observado hasta el reinicio informado. No garantiza el uso futuro.", "fr": "Projection linéaire du rythme observé jusqu’à la réinitialisation indiquée. Ce n’est pas une garantie d’usage futur.", "de": "Lineare Fortschreibung des beobachteten Tempos bis zum gemeldeten Zurücksetzen. Keine Zusage für künftige Nutzung.", "pt-BR": "Projeção linear do ritmo observado até a redefinição informada. Não é uma garantia de uso futuro.", "it": "Proiezione lineare del ritmo osservato fino al ripristino indicato. Non è una garanzia dell’uso futuro."],
    "quotaAlerts": ["en": "Quota alerts", "zh-Hant": "額度提醒", "zh-Hans": "额度提醒", "ja": "使用枠の通知", "ko": "한도 알림", "es": "Alertas de cuota", "fr": "Alertes de quota", "de": "Kontingent-Hinweise", "pt-BR": "Alertas de cota", "it": "Avvisi di quota"],
    "quotaAlertsHelp": ["en": "Notify once per reset cycle when a quota reaches 90% or would run out before it resets at the current pace.", "zh-Hant": "額度達 90%，或照目前速度會在重置前用完時，每個重置週期通知一次。", "zh-Hans": "额度达到 90%，或按当前速度会在重置前用完时，每个重置周期通知一次。", "ja": "使用率が 90% に達したとき、または現在のペースでリセット前に上限に達する見込みのとき、リセット周期ごとに 1 回通知します。", "ko": "한도가 90%에 도달하거나 현재 속도로 재설정 전에 소진될 것으로 보이면 재설정 주기마다 한 번 알립니다.", "es": "Avisa una vez por ciclo cuando una cuota llega al 90% o se agotaría antes de reiniciarse al ritmo actual.", "fr": "Prévient une fois par cycle lorsqu’un quota atteint 90% ou serait épuisé avant sa réinitialisation au rythme actuel.", "de": "Benachrichtigt einmal pro Zyklus, wenn ein Kontingent 90% erreicht oder beim aktuellen Tempo vor dem Zurücksetzen aufgebraucht wäre.", "pt-BR": "Avisa uma vez por ciclo quando uma cota chega a 90% ou se esgotaria antes da redefinição no ritmo atual.", "it": "Avvisa una volta per ciclo quando una quota raggiunge il 90% o si esaurirebbe prima del ripristino al ritmo attuale."],
    "alertHighUsage": ["en": "used", "zh-Hant": "已使用", "zh-Hans": "已使用", "ja": "使用済み", "ko": "사용됨", "es": "usado", "fr": "utilisé", "de": "verbraucht", "pt-BR": "usado", "it": "usato"],
    "alertBeforeReset": ["en": "before reset at this pace", "zh-Hant": "照目前速度會在重置前用完", "zh-Hans": "按当前速度会在重置前用完", "ja": "現在のペースではリセット前に上限到達", "ko": "현재 속도면 재설정 전에 소진", "es": "antes del reinicio a este ritmo", "fr": "avant la réinitialisation à ce rythme", "de": "vor dem Zurücksetzen bei diesem Tempo", "pt-BR": "antes da redefinição neste ritmo", "it": "prima del ripristino a questo ritmo"],
]
