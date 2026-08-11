# Security Policy

## Supported versions

Trackify has not published a V1 release yet. Until then, security fixes apply to the default branch only.

After V1, the latest stable release line is supported. Users should update to the newest patch before reporting an issue against an older build. Older release lines receive no guaranteed fixes unless this file names them explicitly. This small-project policy avoids promising maintenance capacity that does not exist; a future workplace or public support commitment can expand it deliberately.

## Reporting a vulnerability

Do not open a public issue for suspected vulnerabilities, leaked credentials, unsafe update behavior, privacy failures, or fixture-redaction failures.

Use GitHub's private vulnerability-reporting flow:

https://github.com/vucinatim/trackify/security/advisories/new

Include:

- The affected version or commit.
- Reproduction steps using synthetic data.
- The expected and observed security boundary.
- Any evidence that sensitive data left the machine.

Do not include real provider credentials, private repository content, conversation text, or customer data. The maintainer will acknowledge a complete report as soon as practical and coordinate remediation and disclosure based on severity. There is no guaranteed response-time SLA before one is published here.

## Security model

Trackify's V1 privacy, storage, provider, update, and threat boundaries are defined in [docs/PRIVACY_SECURITY.md](docs/PRIVACY_SECURITY.md).
