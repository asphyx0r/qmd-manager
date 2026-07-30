# Security

Thank you for helping keep QMD Manager safe.

## Supported versions

QMD Manager is maintained from the default branch. Security updates apply to
the latest repository version unless a release policy is documented later.

## Reporting a vulnerability

Please do not disclose security issues publicly before maintainers have had
time to review them.

Report suspected vulnerabilities through GitHub private vulnerability
reporting from the repository's **Security** tab. Do not substitute a guessed
repository URL.

Keep GitHub private vulnerability reporting enabled for this repository. If it
is unavailable, enable another private channel before requesting sensitive
security reports.

Include as much detail as possible:

- A clear description of the issue.
- Steps to reproduce or verify the issue.
- Affected files or configuration.
- Potential impact.
- Any suggested fix or mitigation.

## Scope

Relevant security concerns include:

- Accidental secrets or credentials committed to the repository.
- Unsafe prerequisite installation or lifecycle-script authorization.
- Command-line validation that permits unintended QMD targets.
- Preview behavior that performs an undocumented mutation.
- Documentation or repository automation that encourages insecure usage.

## Out of scope

The following reports are usually out of scope for QMD Manager:

- Vulnerabilities in QMD, Node.js, npm, WinGet, or hosted services that are not
  caused by this repository's configuration or invocation.
- Vulnerabilities in knowledge content managed by users.
- General hardening suggestions without a concrete risk.

## Handling

Maintainers should acknowledge valid reports, investigate the impact, and
document any accepted fix in `CHANGELOG.md`.
