# Validation scope

Version 0.6.1 is tested locally on Apple Silicon macOS. Earlier notes: 0.4.0 was tested with Swift 6.2.4 and Codex CLI 0.153.4. The package declares macOS 13+ / Swift 5.9+; minimum-supported OS/compiler combinations have not all been exercised. The 0.4.0 universal app ZIP was notarized by Apple (status Accepted), stapled, and passed Gatekeeper (`spctl`: Notarized Developer ID) after extraction with a download quarantine flag; it has not yet been opened on an Intel Mac.

## Automated

`./scripts/check.sh` runs the Swift test suite (109 tests in 0.6.1), 7 Python bridge/installer tests, release hygiene checks and, when Node.js is installed, the website (`site/`) and collector (`collector/`) tests. These cover hourly/rolling rates, idle time, independent token counters, observation bounds, resets, missing values, account/plan changes, gaps, legacy preferences/history, RGB bounds, localized strings and English fallbacks, provider timestamps/identity, normalized provider quota fields, exact Cursor member matching, private atomic snapshot writes, status-line preservation/idempotence, protocol failures, token endpoint compatibility, source diagnostic serialization and freshness, task lifecycle, separate account snapshots, event checkpoints, gaps, account switches, reset/correction distinctions, missing-window recovery, source failure deduplication/recovery, period-change labeling, and managed subprocess cleanup. Source export hygiene rejects likely credentials and machine-specific paths without printing matched values.

## Manual

The card has been exercised for blank-space dragging, quota selection, collapse/expand, the settings gear, RGB validation and colors, three concurrent Codex/Spark windows, energy saving, persistence across restart, and the Japanese, English, and Chinese interfaces. New task and diagnostic labels are translated in English and Chinese and use English fallbacks in the other interface languages; the new task and usage-event menu flows still need manual visual review.

Codex quota and reset values were compared with the local app-server response. Claude Code, Antigravity CLI, and Cursor adapters are tested with sanitized fixtures; live accounts for these three providers have not been configured or verified. The provider guide explains this distinction.

Real sleep, physical monitor removal, cross-full-screen-Space behavior, Intel hardware, and every minimum-supported OS combination have not been exhaustively tested. Sleep/resume transport and multi-monitor geometry have deterministic coverage. Hosted CI results are recorded separately from local checks.

## Resource measurement

The native app caches rate calculations until data/settings change and updates only countdown text on clock ticks. Hidden cards invalidate their UI timer. Energy saver polls Codex every 120 seconds and updates visible countdowns every 15 seconds. Standard mode uses 60 seconds and 1 second. Optional bridge imports check file metadata every 15 seconds and parse only changed, bounded files. No model requests are sent.

Measurements below are short local observations, not guarantees for other machines or account sizes. The managed Codex app-server is included separately because it accounts for most of the memory footprint.

Observed on the development Mac over 60.1 seconds with energy saver enabled, three quota rows, custom RGB colors, and bridge imports disabled:

| Process | Peak resident memory | Average CPU during observation |
|---|---:|---:|
| Native widget | 27.1 MiB | 0.05% of one core |
| Managed Codex app-server | 67.4 MiB | 0.05% of one core |

CPU was calculated from process CPU-time differences divided by elapsed wall time; resident memory was sampled every ten seconds. This short sample may not include a full 120-second polling cycle, and startup/network bursts can be higher. These figures do not establish a controlled before/after speedup.

## First public release review

The release review covered transport lifecycle and read-only requests, account/window separation, bridge normalization and bounded input, settings persistence, source packaging, installation scripts, repository history, and public documentation. It corrected cross-provider freshness/error labels, inconsistent invalid percentage display, expired diagnostic rates, an old hardcoded protocol client version, reinstall behavior when the app was launched from a different path, and private permissions at creation time for provider settings backups/temporary files. No model turns or credential-file reads are used by the widget.

The source distribution is the supported public artifact. Prebuilt App binaries remain local ad-hoc builds and are not attached to the public release. This is a functional/code review with automated checks, not a claim of exhaustive security certification. Provider live-account and hardware limitations above remain applicable.
