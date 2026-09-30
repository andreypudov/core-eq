# Contributing to CoreEQ

Thanks for your interest in improving CoreEQ. This page covers where to find
the documentation, how to report bugs, and how to format commits and pull
requests.

## Documentation

- [README.org](README.org): what CoreEQ does, installation, and usage.
- [docs/DEVELOPMENT.org](docs/DEVELOPMENT.org): toolchain, building, running,
  testing, and releases. Start here before making changes.
- [docs/ARCHITECTURE.org](docs/ARCHITECTURE.org): how the app is put together.
- [docs/ROADMAP.org](docs/ROADMAP.org): planned work and known issues.
- [docs/RELEASE_NOTES.org](docs/RELEASE_NOTES.org): what shipped in each release.
- [SECURITY.md](SECURITY.md): how to report a vulnerability.

Project documentation is written in Org format (`.org`).

## Reporting bugs

Open an issue and include:

- the macOS version and the CoreEQ version,
- the output device (for example, built-in speakers, AirPods, or a USB
  interface),
- what you expected and what happened instead,
- the diagnostics report from **Settings → Diagnostics → Copy**.

Most audio problems depend on the device, so the report is the most useful
part.

## Discuss larger changes first

For a new feature, a UI change, or anything that changes existing behavior,
open an issue to discuss it before writing code. Small fixes and documentation
improvements can go straight to a pull request.

## Project constraints

- **No third-party dependencies.** CoreEQ uses system frameworks only.
- **Native macOS behavior.** The UI follows macOS conventions and system
  controls. Include before and after screenshots for UI changes.
- **Audio changes are tested on hardware.** Changes to audio capture or
  processing should also pass `make audio-test`, which runs on real hardware
  and is not part of CI. See
  [docs/DEVELOPMENT.org](docs/DEVELOPMENT.org) for its setup.

## Before opening a pull request

- Run `make test` and `make lint`. Both must pass. `make format` applies the
  formatting rules.
- Keep each pull request focused on one change.
- Update the relevant documentation when behavior changes.

## Commit messages and pull request titles

Pull requests are squash-merged, so the pull request title becomes the commit
message. Both follow the same format: a prefix, a space, and a short summary in
lowercase and the past tense.

| Prefix | Meaning                        |
| ------ | ------------------------------ |
| `+`    | feature                        |
| `!`    | bug fix                        |
| `~`    | refactor / no behavior change  |
| `#`    | docs                           |
| `^`    | tooling / dependencies         |
| `-`    | removal                        |

Examples:

```
+ added preset import and export
! fixed silent output on aggregate devices
~ moved import summary out of the sidebar view
# documented import and export in the readme
^ migrated ci to macos 26
- removed unused clipboard helpers
```

The pull request number is appended on merge, for example
`+ added preset import and export (#25)`.

The pull request description should say what changed and why, and how it was
tested.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), the same license as the project.
