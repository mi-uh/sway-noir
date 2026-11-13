#!/usr/bin/env python3
"""Decide whether changed files need the expensive Fedora compatibility job."""

import json
import os
from pathlib import Path
import re
import subprocess


def relevant_path(path):
    if path.lower().endswith(".md"):
        return False
    return path in {"dependencies.list", "install.sh", "start-sway-noir"} or path.startswith(
        ("session/", "tests/", ".github/workflows/", ".github/scripts/")
    )


def needs_fedora(event_name, event, repository):
    if event_name == "workflow_dispatch":
        return True, "manual compatibility check"
    if not isinstance(event, dict):
        return True, "event data unavailable; checking conservatively"
    if event_name == "push":
        base, head = event.get("before"), event.get("after")
        separator = ".."
    elif event_name == "pull_request":
        try:
            base = event["pull_request"]["base"]["sha"]
            head = event["pull_request"]["head"]["sha"]
        except (KeyError, TypeError):
            return True, "PR comparison unavailable; checking conservatively"
        # Ignore unrelated changes added to the base branch after the PR forked.
        separator = "..."
    else:
        return True, "unknown event; checking conservatively"

    for revision in (base, head):
        if not isinstance(revision, str) or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", revision):
            return True, "comparison revisions unavailable; checking conservatively"
        if set(revision) == {"0"}:
            return True, "initial push; running full compatibility check"
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "-z", f"{base}{separator}{head}", "--"],
            cwd=repository, capture_output=True, check=True, timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return True, "Git comparison unavailable; checking conservatively"
    paths = [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]
    required = any(relevant_path(path) for path in paths)
    status = "needed" if required else "not needed"
    return required, f"inspected {len(paths)} changed paths; Fedora compatibility check {status}"


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    except (KeyError, OSError, ValueError):
        event = None
    required, reason = needs_fedora(os.environ.get("GITHUB_EVENT_NAME"), event, Path.cwd())
    value = "true" if required else "false"
    print(f"fedora={value}: {reason}")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with Path(output).open("a") as stream:
            stream.write(f"fedora={value}\n")


if __name__ == "__main__":
    main()
