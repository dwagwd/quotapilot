import Foundation

public struct L10n {
    public let language: WidgetLanguage
    public init(_ language: WidgetLanguage) { self.language = language }
    public var code: String {
        if language != .system { return language.rawValue }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") {
            return preferred.contains("Hant") || preferred.contains("TW") || preferred.contains("HK") || preferred.contains("MO") ? "zh-Hant" : "zh-Hans"
        }
        return WidgetLanguage.allCases.first { $0 != .system && preferred.hasPrefix($0.rawValue.split(separator: "-")[0]) }?.rawValue ?? "en"
    }
    public var locale: Locale { Locale(identifier: code) }
    public func text(_ key: String) -> String { Self.table[key]?[code] ?? Self.table[key]?["en"] ?? key }
    public func unit(_ unit: TimeUnit, short: Bool = false) -> String { text(unit.rawValue + (short ? "Short" : "")) }
    public func duration(_ minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return text("cycleUnknown") }
        if m % 10080 == 0 { return "\(m/10080) \(text("weekShort"))" }
        if m % 1440 == 0 { return "\(m/1440) \(text("dayShort"))" }
        if m % 60 == 0 { return "\(m/60) \(text("hourShort"))" }
        return "\(m) \(text("minuteShort"))"
    }
    public func countdown(_ reset: Double?, now: Double) -> String {
        guard let reset, reset.isFinite else { return text("resetUnknown") }
        guard reset > now else { return text("waitingReset") }
        let seconds = Int(min(reset-now, 315360000))
        if seconds >= 86400 { return "\(seconds/86400)\(text("dayShort")) \(seconds%86400/3600)\(text("hourShort")) \(seconds%3600/60)\(text("minuteShort"))" }
        return String(format: "%02d:%02d:%02d", seconds/3600, seconds%3600/60, seconds%60)
    }
    public func number(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.*f", locale: locale, decimals, value)
    }
    public func compact(_ value: Double) -> String {
        if value >= 1_000_000_000 { return number(value/1_000_000_000)+"B" }
        if value >= 1_000_000 { return number(value/1_000_000)+"M" }
        if value >= 1000 { return number(value/1000)+"K" }
        return number(value, decimals: 0)
    }
    public static let table: [String: [String: String]] = {
        var result = baseTable
        for (key, values) in agentFallbackTranslations {
            result[key, default: [:]].merge(values) { _, new in new }
        }
        for (key, values) in agentTranslations {
            result[key, default: [:]].merge(values) { _, new in new }
        }
        for (key, values) in forecastTranslations {
            result[key, default: [:]].merge(values) { _, new in new }
        }
        for (key, values) in featureTranslations {
            result[key, default: [:]].merge(values) { _, new in new }
        }
        for (key, values) in extraTranslations {
            result[key, default: [:]].merge(values) { _, new in new }
        }
        return result
    }()
    private static let baseTable: [String: [String: String]] = [
        "accountTokens": ["en": "Account tokens", "zh-Hant": "帳號 tokens", "zh-Hans": "账号 tokens"],
        "observationUnit": ["en": "Observation unit", "zh-Hant": "觀測單位", "zh-Hans": "观测单位"],
        "settings": ["en": "Settings", "zh-Hant": "設定", "zh-Hans": "设置"],
        "language": ["en": "Language", "zh-Hant": "語言", "zh-Hans": "语言"],
        "system": ["en": "Follow system", "zh-Hant": "跟隨系統", "zh-Hans": "跟随系统"],
        "observation": ["en": "Observation window", "zh-Hant": "觀測區間", "zh-Hans": "观测区间"],
        "rateUnit": ["en": "Rate display unit", "zh-Hant": "速度顯示單位", "zh-Hans": "速度显示单位"],
        "minute": ["en": "Minutes", "zh-Hant": "分鐘", "zh-Hans": "分钟"],
        "hour": ["en": "Hours", "zh-Hant": "小時", "zh-Hans": "小时"],
        "day": ["en": "Days", "zh-Hant": "天", "zh-Hans": "天"],
        "minuteShort": ["en": "min", "zh-Hant": "分", "zh-Hans": "分"],
        "hourShort": ["en": "h", "zh-Hant": "時", "zh-Hans": "时"],
        "dayShort": ["en": "d", "zh-Hant": "天", "zh-Hans": "天"],
        "weekShort": ["en": "wk", "zh-Hant": "週", "zh-Hans": "周"],
        "apply": ["en": "Apply", "zh-Hant": "套用", "zh-Hans": "应用"],
        "cancel": ["en": "Cancel", "zh-Hant": "取消", "zh-Hans": "取消"],
        "rangeHint": ["en": "Choose a whole-number interval from 1 minute to 30 days.", "zh-Hant": "請輸入整數，總區間可設為 1 分鐘至 30 天。", "zh-Hans": "请输入整数，总区间可设为 1 分钟至 30 天。"],
        "settingsNote": ["en": "Quota = observed plan percentage points. Tokens = account-wide reported activity; updates may lag. Shared quotas cannot be attributed to one model. While collecting, samples stay locally for up to 31 days.", "zh-Hant": "額度＝方案額度百分點；tokens＝帳號回報活動量，更新可能延遲。共享額度無法歸因到單一模型。收集時只在本機保留最近最多 31 天樣本。", "zh-Hans": "额度＝方案额度百分点；tokens＝账号报告活动量，更新可能延迟。共享额度无法归因到单一模型。收集时仅在本机保留最近最多 31 天样本。"],
        "invalidInterval": ["en": "Enter a whole-number duration between 1 minute and 30 days.", "zh-Hant": "請輸入介於 1 分鐘與 30 天之間的整數區間。", "zh-Hans": "请输入介于 1 分钟与 30 天之间的整数区间。"],
        "toggleVisible": ["en": "Show / hide widget", "zh-Hant": "顯示／隱藏小卡", "zh-Hans": "显示／隐藏小卡"],
        "refresh": ["en": "Refresh now", "zh-Hant": "立即更新", "zh-Hans": "立即更新"],
        "toggleCollapsed": ["en": "Collapse / expand", "zh-Hant": "收合／展開", "zh-Hans": "收起／展开"],
        "pin": ["en": "Always on top", "zh-Hant": "保持置頂", "zh-Hans": "保持置顶"],
        "quit": ["en": "Quit Codex Usage", "zh-Hant": "退出 Codex Usage", "zh-Hans": "退出 Codex Usage"],
        "selectWindow": ["en": "Select quota window", "zh-Hant": "選擇額度窗口", "zh-Hans": "选择额度窗口"],
        "dragHint": ["en": "Click to switch quota; drag blank space to move.", "zh-Hant": "點擊切換額度；拖曳空白處移動。", "zh-Hans": "点击切换额度；拖动空白处移动。"],
        "collapse": ["en": "Collapse", "zh-Hant": "收合", "zh-Hans": "收起"],
        "expand": ["en": "Expand", "zh-Hant": "展開", "zh-Hans": "展开"],
        "used": ["en": "Used", "zh-Hant": "已用", "zh-Hans": "已用"],
        "reset": ["en": "Reset", "zh-Hant": "重置", "zh-Hans": "重置"],
        "stale": ["en": "Stale data", "zh-Hant": "資料過期", "zh-Hans": "数据过期"],
        "quota": ["en": "Quota", "zh-Hant": "額度", "zh-Hans": "额度"],
        "account": ["en": "Account", "zh-Hant": "帳號", "zh-Hans": "账号"],
        "collecting": ["en": "Collecting data", "zh-Hant": "累積資料中", "zh-Hans": "正在收集数据"],
        "unavailable": ["en": "Unavailable", "zh-Hant": "未提供", "zh-Hans": "未提供"],
        "unknown": ["en": "Unknown", "zh-Hant": "未知", "zh-Hans": "未知"],
        "cycleUnknown": ["en": "Unknown window", "zh-Hant": "週期未知", "zh-Hans": "周期未知"],
        "resetUnknown": ["en": "Reset time unknown", "zh-Hant": "重置時間未知", "zh-Hans": "重置时间未知"],
        "waitingReset": ["en": "Awaiting reset confirmation", "zh-Hant": "等待重置確認", "zh-Hans": "等待重置确认"],
        "points": ["en": "%", "zh-Hant": "%", "zh-Hans": "%"],
        "last": ["en": "Last", "zh-Hant": "近", "zh-Hans": "近"],
        "estimate": ["en": "estimate", "zh-Hant": "估算", "zh-Hans": "估算"],
        "observed": ["en": "Observed", "zh-Hant": "已觀測", "zh-Hans": "已观测"],
        "updated": ["en": "Last update", "zh-Hant": "最後更新", "zh-Hans": "最后更新"],
        "plan": ["en": "Plan", "zh-Hant": "方案", "zh-Hans": "方案"],
        "noQuota": ["en": "No quota data for this account", "zh-Hant": "此帳號未提供額度資料", "zh-Hans": "此账号未提供额度数据"],
        "connecting": ["en": "Connecting…", "zh-Hant": "正在連線…", "zh-Hans": "正在连接…"],
        "asleep": ["en": "Paused during sleep", "zh-Hant": "睡眠期間暫停更新", "zh-Hans": "睡眠期间暂停更新"],
        "clientMissing": ["en": "Codex not found. Install the desktop app or CLI.", "zh-Hant": "找不到 Codex，請先安裝桌面 App 或 CLI。", "zh-Hans": "找不到 Codex，请先安装桌面 App 或 CLI。"],
        "disconnected": ["en": "Codex disconnected; reconnecting.", "zh-Hant": "Codex 連線中斷，將自動重連。", "zh-Hans": "Codex 连接中断，将自动重连。"],
        "serviceStopped": ["en": "Codex service stopped; reconnecting.", "zh-Hant": "Codex 服務已停止，將自動重連。", "zh-Hans": "Codex 服务已停止，将自动重连。"],
        "startFailed": ["en": "Could not start the Codex service.", "zh-Hant": "無法啟動 Codex 服務。", "zh-Hans": "无法启动 Codex 服务。"],
        "sendFailed": ["en": "Could not send the usage request.", "zh-Hant": "無法傳送用量查詢。", "zh-Hans": "无法发送用量查询。"],
        "responseTooLarge": ["en": "Codex response exceeded the size limit.", "zh-Hant": "Codex 回應超出大小限制。", "zh-Hans": "Codex 响应超出大小限制。"],
        "readFailed": ["en": "Unable to read quota. Check Codex login and version.", "zh-Hant": "無法讀取額度，請確認 Codex 登入與版本。", "zh-Hans": "无法读取额度，请确认 Codex 登录与版本。"],
        "loginRequired": ["en": "Sign in to Codex with your ChatGPT account.", "zh-Hant": "請在 Codex 登入 ChatGPT 帳號。", "zh-Hans": "请在 Codex 登录 ChatGPT 账号。"],
        "invalidQuota": ["en": "Could not parse quota. Check your Codex version.", "zh-Hant": "無法解析額度，請檢查 Codex 版本。", "zh-Hans": "无法解析额度，请检查 Codex 版本。"],
        "timeout": ["en": "Request timed out; retrying.", "zh-Hant": "查詢逾時，將自動重試。", "zh-Hans": "查询超时，将自动重试。"],
        "tokensHelp": ["en": "Account-wide reported token counter. This is not model-specific and is not a quota conversion. A zero rate means no reported increase during observation.", "zh-Hant": "帳號累積 token 回報計數，並非單一模型用量，也不是額度換算。速度為零表示觀測期間未回報增加。", "zh-Hans": "账号累计 token 报告计数，并非单一模型用量，也不是额度换算。速度为零表示观测期间未报告增加。"],
        "quotaHelp": ["en": "%/h means percentage points per hour: 20% to 25% in one hour = 5%/h. It is not relative percentage growth or a token multiplier. Model-specific attribution is unavailable for shared buckets.", "zh-Hant": "%/時代表每小時額度百分點變化：一小時由 20% 至 25% = 5%/時，不是相對成長率或 token 倍率。共享窗口不提供各模型歸因。", "zh-Hans": "%/时代表每小时额度百分点变化：一小时由 20% 至 25% = 5%/时，不是相对增长率或 token 倍率。共享窗口不提供各模型归因。"],
        "preview": ["en": "Preview", "zh-Hant": "預覽", "zh-Hans": "预览"]
    ]
}
