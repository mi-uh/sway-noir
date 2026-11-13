#!/usr/bin/bash
# Sway assertions intentionally match literal variables, not shell expansions.
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
readonly repo_root test_root
readonly screenshot="$repo_root/session/screenshot"
readonly mock_bin="$test_root/bin"

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

install -d "$mock_bin"
# A closed command path prevents accidental captures with host desktop tools.
for command_name in mkdir mktemp rm; do
    ln -s "$(type -P "$command_name")" "$mock_bin/$command_name"
done
cat > "$mock_bin/date" <<'EOF'
#!/usr/bin/bash
[[ "$*" == '+%Y-%m-%d_%H-%M-%S' ]] || exit 2
printf '2026-11-11_12-34-56\n'
EOF
cat > "$mock_bin/slurp" <<'EOF'
#!/usr/bin/bash
printf 'called\n' >> "$SLURP_LOG"
case "${SLURP_MODE:-select}" in
    cancel) exit 1 ;;
    empty) exit 0 ;;
    *) printf '10,20 300x200\n' ;;
esac
EOF
cat > "$mock_bin/grim" <<'EOF'
#!/usr/bin/bash
printf '%s\0' "$@" >> "$GRIM_LOG"
output="${@: -1}"
case "${GRIM_MODE:-capture}" in
    fail) printf 'partial image\n' > "$output"; exit 7 ;;
    empty) : > "$output" ;;
    *) printf '\211PNG\r\n\032\nmock screenshot\n' > "$output" ;;
esac
EOF
chmod 755 "$mock_bin/date" "$mock_bin/slurp" "$mock_bin/grim"

new_case() {
    case_root="$test_root/$1"
    case_bin="$case_root/bin"
    install -d "$case_root"
    cp -a -- "$mock_bin" "$case_bin"
    export HOME="$case_root/home with spaces"
    export GRIM_LOG="$case_root/grim.log"
    export SLURP_LOG="$case_root/slurp.log"
    unset GRIM_DEFAULT_DIR XDG_PICTURES_DIR GRIM_MODE SLURP_MODE
    : > "$GRIM_LOG"
    : > "$SLURP_LOG"
}

capture() {
    status=0
    PATH="$case_bin" "$screenshot" "$@" > "$case_root/output.log" 2> "$case_root/error.log" || status=$?
}

assert_no_capture() {
    [[ ! -s "$GRIM_LOG" ]] || fail 'grim ran without a selected region'
    [[ ! -e "$HOME/Pictures" ]] || fail 'cancelled/unavailable selection created a destination'
    [[ -z "$(find "$case_root" -name '*.png' -print -quit)" ]] || fail 'unexpected screenshot file'
}

new_case full
rm -- "$case_bin/slurp"
capture full
[[ "$status" == 0 ]] || fail 'full-screen capture requires slurp or clipboard tools'
output="$(cat "$case_root/output.log")"
[[ -s "$output" ]] || fail 'full-screen capture did not save an image'
[[ "$output" == "$HOME/Pictures/Screenshots/"* ]] || fail 'default output directory is incorrect'
mapfile -d '' -t arguments < "$GRIM_LOG"
[[ "${#arguments[@]}" == 3 && "${arguments[0]}" == -t && "${arguments[1]}" == png &&
   "${arguments[2]}" == "$output" ]] || fail 'full-screen command arguments are incorrect'
[[ ! -s "$SLURP_LOG" ]] || fail 'full-screen capture invoked the region selector'
[[ "$(stat -c '%a' "$output")" == 600 ]] || fail 'screenshot permissions are not private'

# The fixed clock makes collision/overwrite handling deterministic, including
# concurrent captures with the same timestamp.
for number in 1 2 3; do
    PATH="$case_bin" "$screenshot" full > "$case_root/concurrent-$number.log" &
done
wait
mapfile -t images < <(find "$HOME/Pictures/Screenshots" -name '*.png' -type f)
[[ "${#images[@]}" == 4 ]] || fail 'same-second captures overwrote each other'
for image in "${images[@]}"; do
    [[ "${image##*/}" =~ ^Screenshot_2026-11-11_12-34-56\.[[:alnum:]]{6}\.png$ ]] ||
        fail 'screenshot name does not include timestamp and unique suffix'
    [[ -s "$image" ]] || fail 'concurrent capture left an empty image'
done

new_case region
capture region
[[ "$status" == 0 ]] || fail 'region capture failed'
output="$(cat "$case_root/output.log")"
mapfile -d '' -t arguments < "$GRIM_LOG"
[[ "${#arguments[@]}" == 5 && "${arguments[0]}" == -t && "${arguments[1]}" == png &&
   "${arguments[2]}" == -g && "${arguments[3]}" == '10,20 300x200' &&
   "${arguments[4]}" == "$output" ]] || fail 'selected geometry was not passed as one argument'
[[ -s "$output" ]] || fail 'region capture did not save an image'

new_case default-region
capture
[[ "$status" == 0 && -s "$SLURP_LOG" ]] || fail 'default mode does not select a region'

for selection in cancel empty; do
    new_case "$selection"
    export SLURP_MODE="$selection"
    capture region
    [[ "$status" == 0 ]] || fail 'cancelling selection was treated as a capture error'
    assert_no_capture
done

new_case missing-slurp
rm -- "$case_bin/slurp"
capture region
[[ "$status" != 0 ]] || fail 'missing slurp was not reported'
grep -Fq 'require optional slurp' "$case_root/error.log" || fail 'missing selector error is unclear'
assert_no_capture

new_case missing-grim
rm -- "$case_bin/grim"
capture full
[[ "$status" != 0 ]] || fail 'missing grim was not reported'
grep -Fq 'require grim' "$case_root/error.log" || fail 'missing backend error is unclear'
assert_no_capture

for result in fail empty; do
    new_case "backend-$result"
    export GRIM_MODE="$result"
    capture full
    [[ "$status" != 0 ]] || fail 'unsuccessful capture returned success'
    [[ -z "$(find "$HOME" -name '*.png' -print -quit)" ]] || fail 'failed capture left a partial or empty image'
done

new_case quoted-path
export GRIM_DEFAULT_DIR="$case_root/album 'quotes' ; literal \$(not-a-command)"
capture region
[[ "$status" == 0 ]] || fail 'capture into a path with shell metacharacters failed'
output="$(cat "$case_root/output.log")"
[[ "$output" == "$GRIM_DEFAULT_DIR/"* && -s "$output" ]] || fail 'destination path was not quoted safely'

new_case pictures-directory
export XDG_PICTURES_DIR="$case_root/My pictures"
capture full
output="$(cat "$case_root/output.log")"
[[ "$status" == 0 && "$output" == "$XDG_PICTURES_DIR/Screenshots/"* ]] ||
    fail 'XDG_PICTURES_DIR was ignored'

new_case relative-directory
export GRIM_DEFAULT_DIR='relative-output'
capture full
[[ "$status" != 0 && ! -s "$GRIM_LOG" ]] || fail 'relative destination was accepted'

new_case invalid-mode
capture invalid
[[ "$status" == 2 ]] || fail 'invalid mode was accepted'
assert_no_capture
capture full extra-argument
[[ "$status" == 2 ]] || fail 'unexpected arguments were accepted'
assert_no_capture

grep -Fqx 'bindsym Print exec $screenshot_command region' \
    "$repo_root/sway/config.d/60-keybindings.conf" || fail 'Print does not select a region'
grep -Fqx 'bindsym Shift+Print exec $screenshot_command full' \
    "$repo_root/sway/config.d/60-keybindings.conf" || fail 'Shift+Print does not capture full-screen'

printf 'PASS: screenshot modes, cancellation, unique filenames, quoting, missing optional tools and failure cleanup\n'
