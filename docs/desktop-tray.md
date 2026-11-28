# QuotaPilot tray app (Windows and Linux)

`desktop/QuotaPilotTray/` is a small C# app (.NET 8, Avalonia 11) that gives Windows and Linux a tray icon and a quota card like the macOS menu bar app. This is milestone 1; see [desktop-parity-plan.md](desktop-parity-plan.md) for what follows.

## What it shows

- **Tray icon** with a tooltip for the tightest quota window, for example `Codex 92% · resets 1h 20m`.
- **Card** (left click on the icon, about 360 px wide, follows the system light or dark mode):
  - one row per quota window: agent, plan, window length, a usage bar with the percentage, and the time until reset. The bar turns amber from 75 % and red from 90 % or when the limit is reached;
  - tokens for the last 24 hours;
  - the router's suggested agent;
  - problems in plain words, for example "Codex not found. Install the desktop app or CLI."
- **Right-click menu**: Refresh, Open stats in terminal (`quotapilot stats`), Start with Windows (Start at login on Linux), About, Quit.
- English and Traditional Chinese, chosen from the system UI language. Set `QUOTAPILOT_TRAY_LANG=zh-TW` (or `en`) to force one. `QuotaPilotTray.exe --show-card` opens the card right after the first read (used by the clean-Windows screenshot check).

## How it works

The app does not read quota itself. Every 60 seconds, and when the card opens or you press Refresh, it runs the `quotapilot` command found next to it (otherwise on `PATH`) with `status --json` and draws the result. Numbers and routing are therefore the same as in the CLI and the macOS app. A failed read keeps the last good rows on the card and adds a line saying what went wrong.

`Core/` holds the CLI runner, the JSON model, formatting and strings (no UI code, unit tested). `UI/` holds the views. `TrayController` ties them together; later windows share its CLI client and `Loc` strings.

## Privacy

The tray app makes no network requests and has no network code. It only starts the `quotapilot` command beside it (never itself: the tray exe is named `QuotaPilotTray.exe` so it cannot collide with `quotapilot.exe` on case-insensitive Windows file systems) and, on request, a terminal or your browser (About links). What the command itself reads and sends is described in [PRIVACY.md](../PRIVACY.md). "Start with Windows" writes one value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`; on Linux it writes `~/.config/autostart/quotapilot-tray.desktop`. Turning the option off removes it.

## Install

- **Windows**: extract `quotapilot-windows-x64.zip` into one folder and double-click `QuotaPilotTray.exe`. `quotapilot.exe` in the same folder is the command-line tool. The exe is not signed yet (SignPath application in progress), so SmartScreen may ask for confirmation.
- **Linux**: the release tarball does not include the tray app yet (planned). Build it with the .NET 8 SDK: `dotnet publish desktop/QuotaPilotTray -c Release -r linux-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true`, and put `quotapilot` (from the CLI archive) next to the result `QuotaPilotTray`. GNOME shows tray icons only with an AppIndicator extension; KDE, XFCE and others work out of the box. The runtime needs `libicu`.

## Build and test

```sh
dotnet test desktop/QuotaPilotTray.Tests          # parsing, formatting, strings, autostart, card rendering
dotnet run --project desktop/QuotaPilotTray       # tray app (needs quotapilot on PATH, or QUOTAPILOT_TRAY_CLI=<path>)
```

The tests include a headless Avalonia rendering of the card for several fixtures, themes and languages. PNGs are written to `screenshots/` beside the test binary (or to `QUOTAPILOT_SCREENSHOT_DIR`) and uploaded by the `Desktop` workflow as artifacts. The fixtures in `desktop/QuotaPilotTray.Tests/Fixtures/` follow the real `quotapilot status --json` output, including `clientMissing` and a reached limit.

## Known limits (milestone 1)

- The card opens at the bottom right of the primary screen's work area rather than exactly at the icon.
- No notifications, settings window, statistics window or card styles yet.
- Linux packaging and Windows code signing are open.
