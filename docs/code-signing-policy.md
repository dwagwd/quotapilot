# Code signing policy

## What is signed

This policy covers Windows builds of `quotapilot.exe` in the release ZIP. The [release workflow](../.github/workflows/release.yml) builds them from the tagged source on GitHub-hosted runners.

## Signing status

Windows builds are not code-signed yet. QuotaPilot applied to the SignPath Foundation program (free code signing provided by SignPath.io, https://about.signpath.io, certificate by SignPath Foundation, https://signpath.org) on 2026-11-28; the application was declined for now because the project does not yet have enough community adoption, and we plan to reapply later. Until then Windows may show an "unknown publisher" warning; verify the download against the SHA-256 file published with each release.

## Team roles

- **Committers and reviewers** are repository members with write access, currently @dwagwd. They review every outside change in a pull request.
- **Approvers** manually approve signing requests. @dwagwd approves every signing request.
- All team members use multi-factor authentication for GitHub and SignPath.

## Privacy

The QuotaPilot Windows CLI sends nothing to other networked systems unless the user enables or invokes a feature that does. Anonymous statistics sharing is off by default. See the [privacy policy](../PRIVACY.md).
