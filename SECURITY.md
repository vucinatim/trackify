# Security Policy

## Supported versions

Trackify has not published a V1 release yet. Until then, security fixes apply to the default branch only.

After V1, this file will list supported release lines and their security-update windows.

## Reporting a vulnerability

Do not open a public issue for suspected vulnerabilities, leaked credentials, unsafe update behavior, privacy failures, or fixture-redaction failures.

Use GitHub's private vulnerability-reporting flow:

https://github.com/vucinatim/trackify/security/advisories/new

Include:

- The affected version or commit.
- Reproduction steps using synthetic data.
- The expected and observed security boundary.
- Any evidence that sensitive data left the machine.

Do not include real provider credentials, private repository content, conversation text, or customer data. The maintainer will acknowledge a complete report as soon as practical and coordinate remediation and disclosure based on severity.

## Security model

Trackify's V1 privacy, storage, provider, update, and threat boundaries are defined in [docs/PRIVACY_SECURITY.md](docs/PRIVACY_SECURITY.md).
