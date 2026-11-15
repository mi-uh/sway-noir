# Sway Noir project rules

These rules apply to the entire repository.

## Documentation

Write project documentation in English. Keep it minimal: necessary commands and
brief descriptions only. Avoid lengthy explanations and repeated instructions;
link to existing documentation instead.

Organize by purpose with meaningful headings and selective emphasis, not long,
unbroken bullet lists. Separate prerequisites from the actions to perform.
Briefly state required working directories, privileges, restarts, and
essential safety warnings when relevant.

## Changes and safety

Keep changes focused on the requested task and consistent with existing patterns.
Preserve unrelated work, personal configuration, themes and backups. Do not run
the installer, change host configuration or restart live desktop services without
explicit permission. Isolated tests are safe to run.

Use Bash strict mode where appropriate and quote paths, including paths with
spaces. Validate external input; keep `theme.conf` declarative and never evaluate
it as shell code. Avoid introducing new runtime dependencies.

## Configuration ownership

Edit repository templates, not generated files under
`${XDG_STATE_HOME:-$HOME/.local/state}/sway-noir/current/`.
Keep shared Waybar behavior in `waybar/base.jsonc`; theme files contain appearance
overrides. Preserve theme defaults and the saved bar-position preference.

Keep dependency definitions in `dependencies.list` and managed-file registration
in `session/installer/files.sh`. Preserve installer preflight checks, backups,
ownership checks and rollback behavior. Never overwrite `99-local.conf`.

## Validation

**Prerequisites:** repository root, non-root user, Bash, Python 3 and ShellCheck.
Run the relevant isolated tests for code or configuration changes. Use the full
runner for changes to shared behavior, installation or session lifecycle:

```bash
bash tests/run.sh
```

See [tests/README.md](tests/README.md) for focused suites and manual checks.
Report which checks ran and any limitations. Mocked tests do not replace a live
visual check; never claim graphical validation unless it was performed.

## Git

Use a separate branch for each task and keep one cohesive change per commit.
**Commit or push only when explicitly requested.** Do not rewrite history without
permission.

Write commit messages in English: `<type>: <short description>`.
Allowed types: `feat`, `fix`, `docs`, `refactor`, `chore`, `test`.
Use the imperative, no trailing period, and at most 72 characters for the subject.
Add a body only when needed to explain why the change is necessary.
