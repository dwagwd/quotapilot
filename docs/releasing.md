# Release checklist

## Local preparation

- Run `./scripts/check.sh` and `./scripts/package.sh` on macOS.
- Keep `VERSION`, the base version of `.codex-plugin/plugin.json`, and `CHANGELOG.md` aligned.
- Inspect both ZIPs. The source exporter includes only public source/documentation directories and strips local Codex cachebuster suffixes.
- App ZIP names include the architecture of the build machine. Do not describe a single-architecture package as universal.
- Exercise language settings, invalid/valid intervals, both rate units, account/plan changes, restart, and unsupported-token behavior.
- Keep remaining limitations documented in `docs/validation.md`.

## Before first public launch

- The public source repository is `dwagwd/quotapilot`. Publishing a release requires maintainer authorization, a tested commit, and reviewed release assets.
- Enable GitHub private vulnerability reporting and configure branch protection after CI is available.
- Verify GitHub Actions on the chosen repository; local validation does not mean hosted CI has passed.
- Review the license, project description, screenshots, and source archive for personal data.
- Upload only Developer ID signed, notarized, stapled App ZIPs (see below). Never attach an ad-hoc-signed App ZIP as a ready-to-install asset.

## Signed, notarized app builds

One-time setup on the release Mac:

1. Create a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application). Only the team's Account Holder can create it. `Apple Development` and `Apple Distribution` certificates cannot be used outside the Mac App Store.
2. Save notarization credentials in the keychain: `xcrun notarytool store-credentials codex-widget --apple-id <Apple ID> --team-id <team ID>` and enter an app-specific password from appleid.apple.com.

Then build a universal, signed, notarized, stapled app ZIP:

```sh
QUOTAPILOT_UNIVERSAL=1 \
QUOTAPILOT_SIGN_IDENTITY="Developer ID Application: <name> (<team ID>)" \
QUOTAPILOT_NOTARY_PROFILE=codex-widget \
./scripts/package.sh
```

The script stops if notarization fails and checks the result with `spctl`. It prints the ZIP's SHA-256 for the release notes and the Homebrew cask ([template](homebrew-cask.rb)). Download the uploaded ZIP on a second Mac and open it once before announcing the release.

## Publication

The `Package artifacts` workflow is manual and only uploads build artifacts. It does not publish a GitHub release, create tags, or push source. Create version tags/releases only when the maintainer explicitly chooses to publish. Do not embed local marketplace paths in public instructions.

No public repository, remote, tag, or release is created by the build scripts.
