# Validation

## Prerequisites

Run from the **repository root**, as a normal user. Requires Bash, Python 3
(standard library only) and ShellCheck (`ShellCheck` on Fedora, `shellcheck` on
Debian/Ubuntu and Arch). Tests use isolated fixtures and mocked desktop services;
they do not start a desktop or change host configuration.

## All checks (local and CI)

```bash
bash tests/run.sh
```

The shared runner checks shell syntax, runs ShellCheck, then discovers and runs
all `tests/*-test.sh` and `tests/*-test.py` suites. It stops on the first failure.
Individual suites can still be run as shown below.
The runner prints its ShellCheck version; compatibility is checked with 0.9.0
(Ubuntu 24.04's package) and 0.11.0. Indirect trap and mock callbacks have narrowly
scoped annotations for the diagnostics used by both versions.

## CI scheduling

Workflows run on pull requests and pushes to `main`, not on every development
branch push. A push to an open PR therefore starts only the PR run. A newer run
automatically cancels the previous run of the same workflow for that PR/ref.

- **Regression tests:** runs the shared test runner on Ubuntu 24.04 without
  installing the desktop packages.
- **Secret scan:** checks the full fetched history and current files.
- **Fedora dependencies:** starts the expensive Fedora 44 job only when changes
  affect `dependencies.list`, `install.sh`, `start-sway-noir`, `session/`, test
  code, or CI workflows/helpers. Markdown-only, screenshot, theme and desktop
  configuration changes use the fast checks without installing Fedora packages.
  PR comparisons use the merge base; pushes inspect the complete pushed range.
  Missing comparison data runs Fedora conservatively. Renames and deletions are
  included in the decision.

All three workflows can also be started through **Actions → workflow → Run
workflow**. A manual Fedora run always performs the full compatibility check.
For unrelated changes the Fedora job is visibly skipped rather than hiding the
whole workflow through a path filter. If branch protection uses required checks,
require the fast `regression` and `gitleaks` jobs as well as the desired Fedora
checks; do not rely only on the conditional Fedora job.

## Secret scanning

CI separately scans the complete fetched Git history and the current files with
Gitleaks 8.30.0. The release archive is SHA-256 verified before execution, matches
are redacted, and no report artifacts are uploaded. All workflows pin checkout
to a commit and disable persisted Git credentials.

With Gitleaks installed, run the same scans locally:

```bash
gitleaks git --log-opts=--all --redact=100 --no-banner --ignore-gitleaks-allow .
gitleaks dir --redact=100 --no-banner --ignore-gitleaks-allow .
```

When upgrading Gitleaks in `.github/workflows/secrets.yml`, update both the
version and its verified release checksum. A scan is a safeguard, not proof
that every possible secret has been detected.

## Installation and session lifecycle

Install/update/uninstall, dependency checks, login paths, Atomic redirects,
portals, logout and screenshot handling:

```bash
bash tests/install-test.sh
bash tests/preflight-test.sh
bash tests/registry-test.sh
bash tests/session-test.sh
python3 tests/startup-test.py
bash tests/portal-test.sh
bash tests/screenshot-test.sh
```

## Audio, dependencies and authentication

Hardware commands, optional features and PolicyKit-agent startup:

Dependency fixtures provide their own distribution identity and package-query
results, so Fedora, Debian/Ubuntu, Arch and Atomic hints do not depend on the host.

```bash
python3 tests/audio-test.py
python3 tests/dependencies-test.py
python3 tests/polkit-test.py
```

## Appearance and theme switching

Waybar configuration, font checks, all bundled themes, headless validation,
visible menu activation errors, persistence and rollback:

```bash
python3 tests/waybar-test.py
python3 tests/theme-test.py
```

## Live smoke test

**Requires a running Sway Noir session.** Save work before logout/suspend checks.

| Check | Expected result |
| --- | --- |
| Switch Rain ↔ Retro ↔ Praxis on all outputs | Correct appearance; windows stay open |
| Open launcher, send notification, lock | Matching theme |
| Test audio keys and authentication prompts | Controls work; no duplicate agent |
| Capture region/full screen; cancel selection | Correct files; no file on cancellation |
| Test screen sharing, suspend/resume, logout/login | Portals work; screen locks; theme persists |

For release validation, record the distribution/version and the result of each
check. In particular, lock manually with `Super+Shift+x` and confirm that only
authentication unlocks it. Then suspend from an unlocked session, resume, and
confirm that the desktop is already locked before accepting input. Also check
that no duplicate Waybar, Mako or authentication agent remains after a new login.
Automatic locking after inactivity is not configured by this profile.

CI checks Fedora package/layout compatibility, not graphical operation.
For graphically tested platforms, see the [README](../README.md#install).

## Installer maintenance

`session/installer/files.sh` defines each managed file's source, destination,
mode, conflict rule and initial action in one record. Profile directories are
derived from those records. Add bundled profile files with
`register_profile_file`, integrations with `register_file`, and login destinations
with `register_login_file`. A new login destination also needs an explicit place
in the named fallback order in `session/login-integration.sh`.

Consumers use named IDs such as `portal`, `session_target` and `launcher`, never
positions in a list. Profile IDs remain relative paths, and integration checksum
keys remain path-based so old installed manifests keep working. Registry tests
check metadata and directory ordering; lifecycle tests also reorder the lists
and add a file to catch hidden position or file-list dependencies.
