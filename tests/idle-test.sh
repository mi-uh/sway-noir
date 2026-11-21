#!/usr/bin/bash
# shellcheck disable=SC2016 # Mock scripts and Sway lines are literal text.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
lock_pid=""
cleanup() {
    [[ -z "$lock_pid" ]] || kill "$lock_pid" 2>/dev/null || true
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# A profile path with spaces checks quoting of the swayidle shell actions.
profile="$test_root/config with spaces/sway-noir"
install -d "$profile/session"
for script in run-apps start-session idle-display; do
    install -m 755 "$repo_root/session/$script" "$profile/session/$script"
done
mock_bin="$test_root/bin"
install -d "$mock_bin"
export IDLE_LOG="$test_root/idle.log"
mock() {
    printf '#!/usr/bin/bash\n%s\n' "$2" > "$mock_bin/$1"
    chmod 755 "$mock_bin/$1"
}
mock swaymsg 'printf "swaymsg %s\n" "$*" >> "$IDLE_LOG"'
mock swayidle 'printf "%s\0" "$@" > "$IDLE_LOG.swayidle"'
mock systemd-run 'printf "%s\n" "$@" > "$IDLE_LOG.systemd-run"'
for name in waybar mako dbus-update-activation-environment systemctl; do mock "$name" 'exit 0'; done
export PATH="$mock_bin:$PATH"

real_lock_running() {
    local comm name
    for comm in /proc/[0-9]*/comm; do
        [[ -O "$comm" ]] || continue
        IFS= read -r name 2>/dev/null < "$comm" || continue
        [[ "$name" != swaylock ]] || return 0
    done
    return 1
}

# Display helper: never blanks an unlocked desktop.
if ! real_lock_running; then
    : > "$IDLE_LOG"
    "$profile/session/idle-display" off-if-locked
    [[ ! -s "$IDLE_LOG" ]] || fail 'displays were turned off without a lock screen'
fi
lock_dir="$test_root/lock"
install -d "$lock_dir"
printf '#!/usr/bin/bash\nwhile true; do sleep 0.05; done\n' > "$lock_dir/swaylock"
chmod 755 "$lock_dir/swaylock"
"$lock_dir/swaylock" &
lock_pid=$!
sleep 0.1
: > "$IDLE_LOG"
"$profile/session/idle-display" off-if-locked
grep -Fqx 'swaymsg -q output * power off' "$IDLE_LOG" || fail 'locked displays were not turned off'
"$profile/session/idle-display" on
grep -Fqx 'swaymsg -q output * power on' "$IDLE_LOG" || fail 'displays were not turned on'
for arguments in '' 'off' 'on extra'; do
    status=0
    # shellcheck disable=SC2086 # Deliberately split test arguments.
    "$profile/session/idle-display" $arguments 2>/dev/null || status=$?
    [[ "$status" == 2 ]] || fail "invalid arguments were accepted: '$arguments'"
done

run_apps() {
    rm -f -- "$IDLE_LOG.swayidle"
    SWAY_NOIR_THEME_DIR="$test_root/theme" "$profile/session/run-apps" lock-screen true true \
        2> "$test_root/run-apps.err"
    mapfile -d '' -t idle_arguments < "$IDLE_LOG.swayidle"
}
printf -v helper '%q' "$profile/session/idle-display"

SWAY_NOIR_IDLE_LOCK_TIMEOUT=600 SWAY_NOIR_LOCKED_DISPLAY_OFF_TIMEOUT=60 run_apps
expected=(-w timeout 600 lock-screen
    timeout 60 "$helper off-if-locked" resume "$helper on"
    timeout 660 "$helper off-if-locked" resume "$helper on"
    after-resume "$helper on" before-sleep lock-screen)
[[ "${idle_arguments[*]}" == "${expected[*]}" ]] ||
    fail "unexpected swayidle arguments: ${idle_arguments[*]}"
# The quoted actions must run through sh -c despite spaces in the path.
: > "$IDLE_LOG"
sh -c "${idle_arguments[6]}"
grep -Fqx 'swaymsg -q output * power off' "$IDLE_LOG" || fail 'quoted display action did not run'

SWAY_NOIR_IDLE_LOCK_TIMEOUT=0 SWAY_NOIR_LOCKED_DISPLAY_OFF_TIMEOUT=30 run_apps
expected=(-w timeout 30 "$helper off-if-locked" resume "$helper on"
    after-resume "$helper on" before-sleep lock-screen)
[[ "${idle_arguments[*]}" == "${expected[*]}" ]] || fail 'manual-lock display timeout is incorrect'

SWAY_NOIR_IDLE_LOCK_TIMEOUT=300 SWAY_NOIR_LOCKED_DISPLAY_OFF_TIMEOUT=0 run_apps
expected=(-w timeout 300 lock-screen before-sleep lock-screen)
[[ "${idle_arguments[*]}" == "${expected[*]}" ]] || fail 'disabled display timeout still blanks displays'

for value in -1 abc 1e3 '600; reboot' 0600 9999999; do
    SWAY_NOIR_IDLE_LOCK_TIMEOUT="$value" SWAY_NOIR_LOCKED_DISPLAY_OFF_TIMEOUT="$value" run_apps
    [[ "${idle_arguments[*]}" == '-w before-sleep lock-screen' ]] ||
        fail "invalid timeout was used: $value"
    grep -Fq 'automatic locking is disabled' "$test_root/run-apps.err" ||
        fail "invalid timeout was not reported: $value"
done
unset SWAY_NOIR_IDLE_LOCK_TIMEOUT SWAY_NOIR_LOCKED_DISPLAY_OFF_TIMEOUT
run_apps
[[ "${idle_arguments[*]}" == '-w before-sleep lock-screen' ]] || fail 'unset timeouts changed idle behavior'

# start-session passes the named options to the application service.
XDG_CONFIG_HOME="$test_root/config with spaces" SWAY_NOIR_SESSION_ID=1-2-3 \
    "$profile/session/start-session" --idle-lock 300 --locked-display-off 45 \
    lock-screen pavucontrol true gammastep
grep -Fqx -- '--setenv=SWAY_NOIR_IDLE_LOCK_TIMEOUT=300' "$IDLE_LOG.systemd-run" ||
    fail 'idle lock timeout was not passed to the session'
grep -Fqx -- '--setenv=SWAY_NOIR_LOCKED_DISPLAY_OFF_TIMEOUT=45' "$IDLE_LOG.systemd-run" ||
    fail 'display-off timeout was not passed to the session'
tail -n 3 "$IDLE_LOG.systemd-run" | tr '\n' ' ' | grep -Fq 'lock-screen true gammastep' ||
    fail 'options shifted the positional session commands'
XDG_CONFIG_HOME="$test_root/config with spaces" SWAY_NOIR_SESSION_ID=1-2-3 \
    "$profile/session/start-session" lock-screen pavucontrol true gammastep
grep -Fqx -- '--setenv=SWAY_NOIR_IDLE_LOCK_TIMEOUT=0' "$IDLE_LOG.systemd-run" ||
    fail 'calls without idle options did not keep the previous behavior'
status=0
SWAY_NOIR_SESSION_ID=1-2-3 "$profile/session/start-session" --idle-lock 2>/dev/null || status=$?
[[ "$status" == 2 ]] || fail 'missing option value was accepted'

# Shipped defaults and the startup line.
grep -Fqx 'set $idle_lock_timeout 600' "$repo_root/sway/config" || fail 'idle lock default changed'
grep -Fqx 'set $locked_display_off_timeout 60' "$repo_root/sway/config" || fail 'display-off default changed'
grep -Fq -- '--idle-lock $idle_lock_timeout --locked-display-off $locked_display_off_timeout' \
    "$repo_root/sway/config.d/99-startup.conf" || fail 'startup does not pass idle settings'

printf 'PASS: idle locking, locked display power, quoting, validation and option passing\n'
