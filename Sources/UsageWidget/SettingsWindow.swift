import AppKit
import UsageCore

final class SettingsWindowController: NSWindowController {
    private var settings: WidgetSettings
    private let applySettings: (WidgetSettings) -> Void
    private let languageMenu = NSPopUpButton()
    private let intervalField = NSTextField()
    private let intervalMenu = NSPopUpButton()
    private let rateMenu = NSPopUpButton()
    private let multiple = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let colors = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let eco = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let bridges = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let alerts = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let autoContinue = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let agentLogs = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var quotaChecks: [(String, NSButton)] = []
    private var rgbFields: [NSTextField] = []
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(settings: WidgetSettings, windows: [(String, String)], onApply: @escaping (WidgetSettings) -> Void) {
        self.settings = settings; applySettings = onApply
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 770),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        let l = L10n(settings.language)
        window.title = "Codex Usage · " + l.text("settings")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 770))
        window.contentView = view
        func label(_ key: String, y: CGFloat) {
            let label = NSTextField(labelWithString: l.text(key))
            label.frame = NSRect(x: 22, y: y + 340, width: 154, height: 22)
            view.addSubview(label)
        }
        label("language", y: 320)
        languageMenu.frame = NSRect(x: 180, y: 657, width: 238, height: 26)
        languageMenu.addItems(withTitles: WidgetLanguage.allCases.map { $0 == .system ? l.text("system") : $0.nativeName })
        languageMenu.selectItem(at: WidgetLanguage.allCases.firstIndex(of: settings.language) ?? 0)
        languageMenu.setAccessibilityLabel(l.text("language"))
        label("observation", y: 274)
        intervalField.frame = NSRect(x: 180, y: 613, width: 93, height: 25)
        intervalField.stringValue = String(settings.intervalValue)
        intervalField.setAccessibilityLabel(l.text("observation"))
        intervalMenu.frame = NSRect(x: 282, y: 611, width: 136, height: 26)
        intervalMenu.addItems(withTitles: TimeUnit.allCases.map { l.unit($0) })
        intervalMenu.selectItem(at: TimeUnit.allCases.firstIndex(of: settings.intervalUnit) ?? 1)
        intervalMenu.setAccessibilityLabel(l.text("observationUnit"))
        label("rateUnit", y: 228)
        rateMenu.frame = NSRect(x: 180, y: 565, width: 238, height: 26)
        rateMenu.addItems(withTitles: TimeUnit.allCases.map { l.unit($0) })
        rateMenu.selectItem(at: TimeUnit.allCases.firstIndex(of: settings.rateUnit) ?? 1)
        rateMenu.setAccessibilityLabel(l.text("rateUnit"))
        let hint = NSTextField(wrappingLabelWithString: l.text("rangeHint"))
        hint.frame = NSRect(x: 22, y: 522, width: 396, height: 34)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString: l.text("settingsNote"))
        note.frame = NSRect(x: 22, y: 423, width: 396, height: 89)
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        multiple.title = l.text("multiple"); multiple.state = settings.options.multiple ? .on : .off
        multiple.frame = NSRect(x: 22, y: 386, width: 396, height: 24)
        multiple.toolTip = l.text("selectionHint")
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 270, width: 396, height: 110))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let list = NSView(frame: NSRect(x: 0, y: 0, width: 370, height: max(100, windows.count * 25)))
        for (index, pair) in windows.enumerated() {
            let check = NSButton(checkboxWithTitle: pair.1, target: nil, action: nil)
            check.frame = NSRect(x: 6, y: list.frame.height - CGFloat(index + 1) * 25, width: 358, height: 24)
            check.state = settings.options.windowIDs.contains(pair.0) ? .on : .off
            check.toolTip = pair.1; list.addSubview(check); quotaChecks.append((pair.0, check))
        }
        scroll.documentView = list
        colors.title = l.text("colors"); colors.state = settings.options.customColors ? .on : .off
        colors.frame = NSRect(x: 22, y: 242, width: 396, height: 24)
        let rgb = [settings.options.foreground, settings.options.background]
        for row in 0..<2 {
            let y = CGFloat(212 - row * 32)
            let caption = NSTextField(labelWithString: l.text(row == 0 ? "foreground" : "background"))
            caption.frame = NSRect(x: 22, y: y, width: 146, height: 22); view.addSubview(caption)
            for (col, value) in [rgb[row].red, rgb[row].green, rgb[row].blue].enumerated() {
                let field = NSTextField(); field.stringValue = String(value)
                field.frame = NSRect(x: 180 + col * 80, y: Int(y), width: 72, height: 24)
                field.setAccessibilityLabel(caption.stringValue + " " + ["R", "G", "B"][col])
                field.toolTip = ["R", "G", "B"][col] + " (0–255)"
                rgbFields.append(field); view.addSubview(field)
            }
        }
        eco.title = l.text("eco"); eco.state = settings.options.energySaver ? .on : .off
        eco.frame = NSRect(x: 22, y: 148, width: 236, height: 24)
        alerts.title = l.text("quotaAlerts"); alerts.state = settings.quotaAlertsEnabled ? .on : .off
        alerts.frame = NSRect(x: 262, y: 148, width: 156, height: 24)
        alerts.toolTip = l.text("quotaAlertsHelp")
        bridges.title = l.text("bridges"); bridges.state = settings.options.bridges ? .on : .off
        bridges.frame = NSRect(x: 22, y: 117, width: 245, height: 24)
        let guide = NSButton(title: l.text("bridgeHelp"), target: self, action: #selector(connectionGuide))
        guide.frame = NSRect(x: 277, y: 115, width: 140, height: 26); guide.bezelStyle = .rounded
        let selectionHint = NSTextField(wrappingLabelWithString: l.text("selectionHint"))
        selectionHint.frame = NSRect(x: 22, y: 80, width: 396, height: 30)
        selectionHint.font = .systemFont(ofSize: 11); selectionHint.textColor = .secondaryLabelColor
        for control in [multiple, scroll, colors, eco, alerts, bridges, guide, selectionHint] { view.addSubview(control) }
        errorLabel.frame = NSRect(x: 22, y: 48, width: 396, height: 32)
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        let cancel = NSButton(title: l.text("cancel"), target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 244, y: 12, width: 82, height: 30); cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: l.text("apply"), target: self, action: #selector(apply))
        apply.frame = NSRect(x: 332, y: 12, width: 88, height: 30); apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        for control in [languageMenu, intervalField, intervalMenu, rateMenu, hint, note, errorLabel, cancel, apply] { view.addSubview(control) }
        // Make room for the agent options below the energy/alert row.
        for control in view.subviews where control.frame.minY >= 148 { control.frame.origin.y += 60 }
        autoContinue.title = l.text("autoContinue"); autoContinue.state = settings.autoContinueEnabled ? .on : .off
        autoContinue.frame = NSRect(x: 22, y: 178, width: 396, height: 24); autoContinue.toolTip = l.text("autoContinueHelp")
        agentLogs.title = l.text("agentLogs"); agentLogs.state = settings.agentLogsEnabled ? .on : .off
        agentLogs.frame = NSRect(x: 22, y: 148, width: 396, height: 24); agentLogs.toolTip = l.text("agentLogsHelp")
        view.addSubview(autoContinue); view.addSubview(agentLogs)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func present() { showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    @objc private func connectionGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/dwagwd/codex-plugin/blob/main/docs/providers.md")!)
    }
    @objc private func cancel() { close() }
    @objc private func apply() {
        guard let value = Int(intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorLabel.stringValue = L10n(settings.language).text("invalidInterval"); return
        }
        var next = settings
        next.language = WidgetLanguage.allCases[languageMenu.indexOfSelectedItem]
        next.intervalValue = value
        next.intervalUnit = TimeUnit.allCases[intervalMenu.indexOfSelectedItem]
        next.rateUnit = TimeUnit.allCases[rateMenu.indexOfSelectedItem]
        let components = rgbFields.compactMap { Int($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard components.count == 6, components.allSatisfy({ (0...255).contains($0) }) else {
            errorLabel.stringValue = L10n(settings.language).text("invalidColor"); return
        }
        var options = settings.options
        options.multiple = multiple.state == .on
        let selected = quotaChecks.filter { $0.1.state == .on }.map { $0.0 }
        guard selected.count <= 4 else { errorLabel.stringValue = L10n(settings.language).text("selectionHint"); return }
        options.windowIDs = selected
        options.customColors = colors.state == .on
        options.foreground = RGBColor(components[0], components[1], components[2])
        options.background = RGBColor(components[3], components[4], components[5])
        options.energySaver = eco.state == .on; options.bridges = bridges.state == .on
        next.options = options
        next.quotaAlertsEnabled = alerts.state == .on
        next.autoContinueEnabled = autoContinue.state == .on
        next.agentLogsEnabled = agentLogs.state == .on
        guard next.isValid else { errorLabel.stringValue = L10n(settings.language).text("invalidInterval"); return }
        applySettings(next); close()
    }
}
