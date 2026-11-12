# Release checklist

**From 0.6.3 no signed app is published; the only prebuilt macOS package is the Homebrew bottle built on GitHub's runners.** Bump `VERSION`, the plugin manifest, the CLI `version` constant, `CHANGELOG.md` and the `tag:` in [`Formula/quotapilot.rb`](../Formula/quotapilot.rb) (its `revision:` stays the all-zero placeholder until the tag exists), run `./scripts/check.sh`, then tag and pin as described in [Source-only release steps](#source-only-release-steps). Homebrew compiles the app on each user's Mac, so nothing is signed with a personal Developer ID and no binary carries the maintainer's machine paths. The signed-build notes below are kept only for a future organization account.

**CI does the heavy work on GitHub's free macOS runners (public repository):** pushing the `vX.Y.Z` tag runs `.github/workflows/release.yml` (checks, source archive, SHA-256, notes from this CHANGELOG section, GitHub Release, Linux and Windows command-line builds, and the Homebrew bottle: built from the tag, installed again from the bottle, signature and build-path checks). Pull requests that touch the app or the formula run the same bottle build and install against the commit under test in `.github/workflows/formula.yml`. CodeQL (JavaScript and Swift) and Dependabot (pinned actions) run from `.github/workflows/codeql.yml` and `.github/dependabot.yml`.


## Source-only release steps

The formula lives in this repository, so it cannot contain the hash of the commit that includes it. The tag therefore points at the release commit, and the next commit pins the formula to it:

1. Bump the versions and `CHANGELOG.md`. In the formula set `tag: "vX.Y.Z"` and keep `revision: "0000000000000000000000000000000000000000"`.
2. Run `./scripts/check.sh`. `scripts/check-release.py` accepts the placeholder only while the `vX.Y.Z` tag does not exist locally.
3. Commit and create the tag on that release commit: `git tag vX.Y.Z`.
4. Run `./scripts/pin-formula.sh vX.Y.Z`. It resolves `git rev-parse "vX.Y.Z^{commit}"`, rewrites both `tag:` and `revision:` in the formula, and refuses to run if the tag does not exist.
5. Commit the pinned formula (for example `Pin formula to vX.Y.Z`) and run `./scripts/check.sh` again; it now requires the formula's revision to equal the tag's commit.
6. Push `main` and the tag.
7. Wait for the `Release` workflow. Its `bottle` job builds the Homebrew bottle on GitHub's macOS runner (ad-hoc signed there, no personal identity), installs it again to prove it pours, and uploads it with `quotapilot-bottle.json` to the release.
8. Run `./scripts/add-bottle.sh vX.Y.Z`. It downloads that JSON and writes the `bottle do` block (release URL and SHA-256) into the formula. Run `./scripts/check.sh`, commit (for example `Add the vX.Y.Z bottle`) and push `main`. From then on `brew install` downloads the bottle in seconds on the Macs it covers (Apple Silicon, the runner's macOS version or newer); other Macs keep building from source.

When bumping to the next version (step 1), delete the `bottle do` block: it belongs to the previous release, and `scripts/check-release.py` fails while it points at another version. Between steps 6 and 8 the formula has no bottle, so installs build from source; nothing breaks.

Never move or re-create a published tag. Homebrew refuses a tag/revision mismatch, and the check fails if the revision no longer matches.

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

The script stops if notarization fails and checks the result with `spctl`. It prints the ZIP's SHA-256 for the release notes and a future Homebrew cask (the repo currently ships a build-from-source formula instead). The app bundle includes the `quotapilot` CLI at `Contents/Helpers/quotapilot`; after installing with Homebrew on a clean Mac, run `quotapilot share --json` to confirm the website's install steps work. Download the uploaded ZIP on a second Mac and open it once before announcing the release.

## Publication

The `Package artifacts` workflow is manual and only uploads build artifacts. It does not publish a GitHub release, create tags, or push source. Create version tags/releases only when the maintainer explicitly chooses to publish. Do not embed local marketplace paths in public instructions.

No public repository, remote, tag, or release is created by the build scripts.
