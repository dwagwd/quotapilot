using System.Globalization;

namespace QuotaPilotTray.Core;

/// <summary>String tables per language, English as the fallback. Adding a language = one more table in <see cref="Tables"/> and a branch in <see cref="LanguageFor"/>.</summary>
public sealed class Loc
{
    public string Language { get; }
    public Loc(string language) { Language = Tables.ContainsKey(language) ? language : "en"; }

    /// <summary>zh-TW, zh-HK, zh-MO and zh-Hant map to Traditional Chinese; every other culture uses English.</summary>
    public static string LanguageFor(CultureInfo culture)
    {
        var name = culture.Name;
        if (name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) &&
            (name.Contains("Hant", StringComparison.OrdinalIgnoreCase) || name.EndsWith("-TW", StringComparison.OrdinalIgnoreCase) ||
             name.EndsWith("-HK", StringComparison.OrdinalIgnoreCase) || name.EndsWith("-MO", StringComparison.OrdinalIgnoreCase)))
            return "zh-Hant";
        return "en";
    }

    public static Loc FromSystem()
    {
        var forced = Environment.GetEnvironmentVariable("QUOTAPILOT_TRAY_LANG");
        return new Loc(!string.IsNullOrEmpty(forced) ? LanguageFor(new CultureInfo(forced)) : LanguageFor(CultureInfo.CurrentUICulture));
    }

    public string this[string key] => Lookup(key) ?? key;
    string? Lookup(string key) =>
        Tables.TryGetValue(Language, out var t) && t.TryGetValue(key, out var v) ? v : (Tables["en"].TryGetValue(key, out var e) ? e : null);
    public string Format(string key, params object[] args) => string.Format(CultureInfo.InvariantCulture, this[key], args);
    public bool Has(string key) => Lookup(key) is not null;

    internal static readonly Dictionary<string, Dictionary<string, string>> Tables = new()
    {
        ["en"] = En,
        ["zh-Hant"] = ZhHant,
    };

    // Error texts match the macOS app's wording.
    static Dictionary<string, string> En => new()
    {
        ["app.name"] = "QuotaPilot",
        ["card.updated"] = "Updated {0}",
        ["card.loading"] = "Reading quota…",
        ["card.noWindows"] = "No quota data yet",
        ["card.tokens"] = "Tokens, last {0} h",
        ["card.suggest"] = "Use next",
        ["card.suggest.none"] = "No agent has room right now",
        ["card.limit"] = "Limit reached",
        ["card.reset"] = "resets in {0}",
        ["card.resetNow"] = "resetting now",
        ["card.resetUnknown"] = "reset time unknown",
        ["card.refresh"] = "Refresh",
        ["tip.line"] = "{0} {1} · resets {2}",
        ["tip.lineNoReset"] = "{0} {1}",
        ["tip.none"] = "QuotaPilot",
        ["tip.error"] = "QuotaPilot · unavailable",
        ["time.dh"] = "{0}d {1}h",
        ["time.hm"] = "{0}h {1}m",
        ["time.m"] = "{0}m",
        ["time.lt1m"] = "<1m",
        ["dur.d"] = "{0}d",
        ["dur.h"] = "{0}h",
        ["dur.m"] = "{0}m",
        ["agent.codex"] = "Codex",
        ["agent.claude"] = "Claude",
        ["reason.mostHeadroom"] = "most room left",
        ["reason.onlyAvailable"] = "the only one with room",
        ["reason.preferred"] = "your preferred agent",
        ["reason.preferredLow"] = "second choice, the first is low",
        ["reason.allLow"] = "all agents are low",
        ["reason.noData"] = "no quota data",
        ["err.clientMissing"] = "Codex not found. Install the desktop app or CLI.",
        ["err.disconnected"] = "Codex disconnected; reconnecting.",
        ["err.serviceStopped"] = "Codex service stopped; reconnecting.",
        ["err.startFailed"] = "Could not start the Codex service.",
        ["err.sendFailed"] = "Could not send the usage request.",
        ["err.responseTooLarge"] = "Codex response exceeded the size limit.",
        ["err.readFailed"] = "Unable to read quota. Check Codex login and version.",
        ["err.loginRequired"] = "Sign in to Codex with your ChatGPT account.",
        ["err.invalidQuota"] = "Could not parse quota. Check your Codex version.",
        ["err.timeout"] = "Request timed out; retrying.",
        ["err.unknown"] = "{0}: {1}",
        ["err.cliMissing"] = "quotapilot was not found next to this app.",
        ["err.cliFailed"] = "quotapilot failed: {0}",
        ["err.cliTimeout"] = "quotapilot did not answer in time.",
        ["err.cliBadOutput"] = "Unexpected output from quotapilot.",
        ["menu.refresh"] = "Refresh",
        ["menu.stats"] = "Open stats in terminal",
        ["menu.autostart.win"] = "Start with Windows",
        ["menu.autostart.linux"] = "Start at login",
        ["menu.about"] = "About QuotaPilot",
        ["menu.quit"] = "Quit",
        ["about.title"] = "About QuotaPilot",
        ["about.version"] = "Version {0}",
        ["about.cli"] = "quotapilot command-line tool {0}",
        ["about.privacy"] = "This app makes no network requests of its own. It only runs the quotapilot command next to it.",
        ["about.website"] = "Website",
        ["about.github"] = "GitHub",
        ["about.close"] = "Close",
    };

    static Dictionary<string, string> ZhHant => new()
    {
        ["app.name"] = "QuotaPilot",
        ["card.updated"] = "更新於 {0}",
        ["card.loading"] = "正在讀取額度…",
        ["card.noWindows"] = "尚無額度資料",
        ["card.tokens"] = "近 {0} 小時 Token",
        ["card.suggest"] = "建議使用",
        ["card.suggest.none"] = "目前沒有可用的額度",
        ["card.limit"] = "已達上限",
        ["card.reset"] = "{0}後重置",
        ["card.resetNow"] = "即將重置",
        ["card.resetUnknown"] = "重置時間未知",
        ["card.refresh"] = "重新整理",
        ["tip.line"] = "{0} {1} · {2}後重置",
        ["tip.lineNoReset"] = "{0} {1}",
        ["tip.none"] = "QuotaPilot",
        ["tip.error"] = "QuotaPilot · 無法讀取",
        ["time.dh"] = "{0}天{1}小時",
        ["time.hm"] = "{0}小時{1}分",
        ["time.m"] = "{0}分",
        ["time.lt1m"] = "不到 1 分",
        ["dur.d"] = "{0} 天",
        ["dur.h"] = "{0} 小時",
        ["dur.m"] = "{0} 分",
        ["agent.codex"] = "Codex",
        ["agent.claude"] = "Claude",
        ["reason.mostHeadroom"] = "剩餘額度最多",
        ["reason.onlyAvailable"] = "唯一有額度的",
        ["reason.preferred"] = "你的偏好",
        ["reason.preferredLow"] = "備選，首選額度偏低",
        ["reason.allLow"] = "所有 agent 額度都偏低",
        ["reason.noData"] = "沒有額度資料",
        ["err.clientMissing"] = "找不到 Codex，請先安裝桌面 App 或 CLI。",
        ["err.disconnected"] = "Codex 連線中斷，將自動重連。",
        ["err.serviceStopped"] = "Codex 服務已停止，將自動重連。",
        ["err.startFailed"] = "無法啟動 Codex 服務。",
        ["err.sendFailed"] = "無法傳送用量查詢。",
        ["err.responseTooLarge"] = "Codex 回應超出大小限制。",
        ["err.readFailed"] = "無法讀取額度，請確認 Codex 登入與版本。",
        ["err.loginRequired"] = "請在 Codex 登入 ChatGPT 帳號。",
        ["err.invalidQuota"] = "無法解析額度，請檢查 Codex 版本。",
        ["err.timeout"] = "查詢逾時，將自動重試。",
        ["err.unknown"] = "{0}：{1}",
        ["err.cliMissing"] = "在此程式旁找不到 quotapilot。",
        ["err.cliFailed"] = "quotapilot 執行失敗：{0}",
        ["err.cliTimeout"] = "quotapilot 未在時限內回應。",
        ["err.cliBadOutput"] = "quotapilot 輸出格式無法辨識。",
        ["menu.refresh"] = "重新整理",
        ["menu.stats"] = "在終端機開啟統計",
        ["menu.autostart.win"] = "開機時自動啟動",
        ["menu.autostart.linux"] = "登入時自動啟動",
        ["menu.about"] = "關於 QuotaPilot",
        ["menu.quit"] = "結束",
        ["about.title"] = "關於 QuotaPilot",
        ["about.version"] = "版本 {0}",
        ["about.cli"] = "quotapilot 命令列工具 {0}",
        ["about.privacy"] = "此程式本身不連網，只會執行旁邊的 quotapilot 命令。",
        ["about.website"] = "網站",
        ["about.github"] = "GitHub",
        ["about.close"] = "關閉",
    };
}
