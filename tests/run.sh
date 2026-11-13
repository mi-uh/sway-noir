#!/usr/bin/bash
set -euo pipefail

if (( $# > 0 )); then
    printf 'Usage: bash tests/run.sh\n' >&2
    exit 2
fi
if (( EUID == 0 )); then
    printf 'Run the test suite as a normal user, not root.\n' >&2
    exit 1
fi
for dependency in bash python3 shellcheck; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'Missing test dependency: %s\n' "$dependency" >&2
        exit 1
    fi
done

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repo_root"

shell_files=()
while IFS= read -r -d '' file; do
    first_line=""
    IFS= read -r first_line < "$file" || true
    case "$first_line" in
        '#!'*bash*) bash -n "$file"; shell_files+=("$file") ;;
        '#!'*/sh) sh -n "$file"; shell_files+=("$file") ;;
    esac
done < <(find . -path './.git' -prune -o -type f \( -name '*.sh' -o -executable \) -print0 | LC_ALL=C sort -z)

printf 'Checking shell syntax and ShellCheck (%s files)\n' "${#shell_files[@]}"
shellcheck --version
shellcheck --external-sources "${shell_files[@]}"

test_count=0
for test in tests/*-test.sh tests/*-test.py; do
    [[ -f "$test" ]] || continue
    printf '\nRunning %s\n' "$test"
    case "$test" in
        *.sh) bash "$test" ;;
        *.py) python3 "$test" ;;
    esac
    test_count=$((test_count + 1))
done
printf '\nPASS: shell checks and all %s test suites\n' "$test_count"
