# Security policy

Security fixes target the latest source release. This project is a local companion and does not host a service.

Report suspected vulnerabilities through [private vulnerability reporting](https://github.com/dwagwd/quotapilot/security/advisories/new). If no private channel is available, open a minimal issue asking the maintainer for a private contact method; do not include exploitation details, credentials, or user data in the public issue.

Useful private reports include affected version, macOS/Codex versions, impact, and a reproducible case using synthetic data.

The widget uses the existing Codex authentication context, stores usage samples locally, and exposes no listening network server. Review changes to subprocess arguments, persistence, release packaging, and data export carefully.
