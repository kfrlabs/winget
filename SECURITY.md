# Security Policy

## Supported Versions

Only the latest major release of this module receives security updates.

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

Please do not report security vulnerabilities through public GitHub issues.

Instead, open a
[private security advisory](https://github.com/kfrlabs/winget/security/advisories/new)
against this repository. Include:

- a description of the issue and its potential impact,
- steps to reproduce (Puppet code, OS and winget versions),
- any relevant logs (redact secrets such as source `--header` values).

We will acknowledge receipt within 7 days and keep you informed while we
investigate and prepare a fix.

## Scope

This module shells out to `winget.exe` and writes `settings.json`; it never
exfiltrates data. When reporting, please distinguish vulnerabilities in this
module from vulnerabilities in winget itself or in the packages it installs
(report those to Microsoft and the package publishers respectively).
