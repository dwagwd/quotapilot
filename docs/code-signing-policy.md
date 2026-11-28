# Code signing policy

## What is signed

This policy covers Windows builds of `quotapilot.exe` in the release ZIP. The [release workflow](../.github/workflows/release.yml) builds them from the tagged source on GitHub-hosted runners.

## Signing status

Windows builds will be signed through the SignPath Foundation program (application pending): free code signing provided by SignPath.io (https://about.signpath.io), certificate by SignPath Foundation (https://signpath.org).

## Team roles

- **Committers and reviewers** are repository members with write access, currently @dwagwd. They review every outside change in a pull request.
- **Approvers** manually approve signing requests. @dwagwd approves every signing request.
- All team members use multi-factor authentication for GitHub and SignPath.

## Privacy

The QuotaPilot Windows CLI sends nothing to other networked systems unless the user enables or invokes a feature that does. Anonymous statistics sharing is off by default. See the [privacy policy](../PRIVACY.md).
