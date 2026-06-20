# Security Policy

## Supported Versions

Only the latest release of this project is actively maintained. Security fixes will not be backported to older versions.

| Version | Supported |
|---------|-----------|
| Latest release | ✅ |
| Older releases | ❌ |

## Reporting a Vulnerability

If you discover a security vulnerability in this project **please do not open a public GitHub issue.** Instead, report it privately so it can be addressed before any public disclosure.

**To report a vulnerability:**

1. Go to the [Security Advisories](https://github.com/xZenLabs/ZenPackageManager/security/advisories) page on GitHub.
2. Click **"Report a vulnerability"** and fill in the details.

Alternatively, you can reach out directly by opening a [private issue](https://github.com/xZenLabs/ZenPackageManager/issues) and marking it as confidential, or by contacting the maintainer through GitHub.

Please include:

- A clear description of the vulnerability and its potential impact
- Steps to reproduce, if applicable
- Any relevant file paths, code references, or log output

## Response

Reported vulnerabilities will be reviewed and responded to as promptly as possible. Once a fix is ready, a new release will be published and the advisory will be made public.

## Scope

This repository is the [Zen Package Manager (ZenPM)](https://github.com/xZenLabs/ZenPackageManager) — a package manager for jailbroken Kindle (and Kobo) devices, built from a local Go HTTP daemon (`zenpm`) and device frontends (Kindle WAF, KOReader plugin). The primary security surface is:   
- The local HTTP daemon (`internal/server`), which listens on `127.0.0.1:8080` and accepts requests from the on-device frontend                                                                                     
- Package install/uninstall execution (`internal/pkg`, `internal/launcher`), which runs scripts on the user's device                                                                                                    
- Manifest signature verification (`internal/repo`), which checks the ed25519 signature on a repository's `manifest.json` before trusting its contents, including the configurable multi-repository trust policy        
- The on-device installers (`installers/kindle`, `installers/kobo`) and the release/build workflow in `.gith
ub/`            
Out-of-scope reports (e.g. vulnerabilities in the package repository content itself, in third-party software distributed through a repository, or in the underlying device OS / jailbreak) should be directed to the appropriate upstream project.    
