# Security Policy

## Supported versions

CoreEQ is supported on its current major line only. Fixes are made on `master`
and shipped in the next release of that line; there are no backports to earlier
point releases.

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |
| < 1.0   | :x:                |

Within 1.x, please reproduce the issue on the **latest released version**
before reporting it — see the [Releases](https://github.com/andreypudov/core-eq/releases)
page, or upgrade with `brew update && brew upgrade --cask core-eq`.

CoreEQ requires macOS 14.2 or later. Vulnerabilities that exist only on
unsupported versions of macOS are out of scope.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Report it privately through GitHub:
[Security → Report a vulnerability](https://github.com/andreypudov/core-eq/security/advisories/new).

Include, as far as you can:

- the CoreEQ version (menu bar → *Settings…* → *About*) and macOS version,
- whether the build came from Homebrew, a release zip, or a local `make build`,
- the output device and, if relevant, the active preset,
- steps to reproduce, and what an attacker gains,
- any crash log or sample from Console.app.

You will get an acknowledgement within a few days. If the report is confirmed,
you will be told when a fix lands and in which release, and credited in the
advisory unless you ask otherwise.

## Scope

CoreEQ is a local, single-user menu bar application. It opens no network
sockets and no listening ports, has no update mechanism of its own, and no
inter-process interface beyond the standard macOS ones. It stores presets and
per-device settings in `UserDefaults` under the user's own account.

In scope:

- Anything that lets code or a user without access to the account read, alter,
  or capture the audio CoreEQ taps, or the settings it stores.
- Privilege escalation, or any path by which CoreEQ writes outside the user's
  own container.
- Crashes in the audio render path that are reachable from untrusted input
  (audio data, preset values, device properties).
- Misuse of the *System Audio Recording* permission — CoreEQ requests it to
  process what you hear, and captured audio must never be written to disk or
  leave the machine.

Out of scope:

- The fact that release builds are **unsigned and unnotarized**, and the
  `xattr -dr com.apple.quarantine` step documented in the README. This is a
  known property of the current distribution, not a vulnerability report;
  building from source avoids it.
- Anything requiring an attacker who already has code execution as the user, or
  root, or physical access to an unlocked machine.
- Audio quality problems, glitches, clicks, or engine restarts that do not
  cross a security boundary — those are ordinary
  [issues](https://github.com/andreypudov/core-eq/issues).
- Vulnerabilities in macOS or Core Audio themselves. Report those to Apple.

## Disclosure

Please give a reasonable window — 90 days is the default — between the report
and any public write-up, and coordinate the timing on the advisory thread so a
fixed release is available first.
