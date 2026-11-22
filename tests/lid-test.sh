#!/usr/bin/bash
# shellcheck disable=SC2016 # Mock scripts and Sway lines are literal text.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

profile="$test_root/config with spaces/sway-noir"
install -d "$profile/session"
for script in run-apps start-session lid-switch; do
    install -m 755 "$repo_root/session/$script" "$profile/session/$script"
done
mock_bin="$test_root/bin"
install -d "$mock_bin"
export LID_LOG="$test_root/lid.log" LOGIND="$test_root/logind"
install -d "$LOGIND"
mock() {
    printf '#!/usr/bin/bash\n%s\n' "$2" > "$mock_bin/$1"
    chmod 755 "$mock_bin/$1"
}
# busctl answers from one file per logind property.
mock busctl 'property="${!#}"; [[ -f "$LOGIND/$property" ]] || exit 1; printf "b %s\n" "$(< "$LOGIND/$property")"'
mock swaymsg 'printf "swaymsg %s\n" "$*" >> "$LID_LOG"'
mock systemctl 'printf "systemctl %s\n" "$*" >> "$LID_LOG"'
mock lock 'printf "lock %s\n" "$*" >> "$LID_LOG"'
mock systemd-inhibit 'printf "systemd-inhibit %s\n" "$*" >> "$LID_LOG"'
mock systemd-run 'printf "%s\n" "$@" > "$LID_LOG.systemd-run"'
for name in swayidle waybar mako dbus-update-activation-environment; do mock "$name" 'exit 0'; done
export PATH="$mock_bin:$PATH" XDG_RUNTIME_DIR="$test_root" SWAY_NOIR_LID_POLL_INTERVAL=1

logind() { printf '%s' "$2" > "$LOGIND/$1"; }
lid() {
    : > "$LID_LOG"
    "$profile/session/lid-switch" "$@"
}
expect_log() {
    local expected="$1" message="$2"
    [[ "$(< "$LID_LOG")" == "$expected" ]] || fail "$message: $(< "$LID_LOG")"
}

logind Docked false
logind LidClosed true

# Charger: lock and displays off; battery: suspend (swayidle locks before sleep).
logind OnExternalPower true
logind LidClosed false
lid close lock suspend lock --ready
expect_log $'lock --ready\nswaymsg -q output * power off' 'charger action is incorrect'
logind OnExternalPower false
lid close lock suspend lock --ready
expect_log 'systemctl suspend' 'battery action is incorrect'

# Unplugging the charger while the lid stays closed applies the battery action.
logind OnExternalPower true
logind LidClosed true
: > "$LID_LOG"
"$profile/session/lid-switch" close lock suspend lock &
watcher=$!
sleep 0.5
grep -Fqx 'swaymsg -q output * power off' "$LID_LOG" || fail 'charger action did not run before unplugging'
# A second close event does not start another watcher.
"$profile/session/lid-switch" close lock suspend lock
logind OnExternalPower false
wait "$watcher"
[[ "$(grep -Fxc 'systemctl suspend' "$LID_LOG")" == 1 ]] || fail 'unplugging did not suspend exactly once'

# Opening the lid ends the watcher without a battery action.
logind OnExternalPower true
: > "$LID_LOG"
"$profile/session/lid-switch" close lock suspend lock &
watcher=$!
sleep 0.5
logind LidClosed false
wait "$watcher"
! grep -Fq 'systemctl' "$LID_LOG" || fail 'opening the lid still suspended'

# Docked, ignore, system and unknown logind state.
logind Docked true
lid close suspend suspend lock
expect_log '' 'docked laptop was not left alone'
logind Docked false
lid close ignore ignore lock
expect_log '' 'ignore action did something'
lid close system system lock
expect_log '' 'system actions did not leave the lid to logind'
logind OnExternalPower false
lid close lock system lock
expect_log 'systemctl suspend' 'single system action did not fall back to suspend'
rm -f -- "$LOGIND/OnExternalPower"
lid close lock ignore lock
expect_log '' 'unknown power source did not use the battery action'

# Opening powers displays on only while lid actions are managed.
lid open lock suspend
expect_log 'swaymsg -q output * power on' 'opening did not power displays on'
lid open system system
expect_log '' 'opening changed displays with system actions'

for arguments in '' 'close lock' 'close lock suspend' 'close reboot suspend lock' \
    'close lock "suspend;reboot" lock' 'open lock suspend extra' 'toggle lock suspend'; do
    status=0
    eval "set -- $arguments"
    "$profile/session/lid-switch" "$@" 2>/dev/null || status=$?
    [[ "$status" == 2 ]] || fail "invalid arguments were accepted: $arguments"
done

# run-apps holds the logind inhibitor only while lid actions are managed.
run_apps() {
    : > "$LID_LOG"
    SWAY_NOIR_THEME_DIR="$test_root/theme" "$profile/session/run-apps" lock-screen true true \
        2> "$test_root/run-apps.err"
}
SWAY_NOIR_LID_AC_ACTION=lock SWAY_NOIR_LID_BATTERY_ACTION=suspend run_apps
grep -Fq 'systemd-inhibit --what=handle-lid-switch' "$LID_LOG" || fail 'managed lid did not inhibit logind'
SWAY_NOIR_LID_AC_ACTION=system SWAY_NOIR_LID_BATTERY_ACTION=system run_apps
[[ ! -s "$LID_LOG" ]] || fail 'system lid actions inhibited logind'
run_apps
[[ ! -s "$LID_LOG" ]] || fail 'unset lid actions inhibited logind'
SWAY_NOIR_LID_AC_ACTION='lock; reboot' SWAY_NOIR_LID_BATTERY_ACTION=suspend run_apps
[[ ! -s "$LID_LOG" ]] || fail 'invalid lid action inhibited logind'
grep -Fq 'logind handles the lid' "$test_root/run-apps.err" || fail 'invalid lid action was not reported'

# start-session passes the named options to the application service.
XDG_CONFIG_HOME="$test_root/config with spaces" SWAY_NOIR_SESSION_ID=1-2-3 \
    "$profile/session/start-session" --lid-ac lock --lid-battery suspend \
    lock-screen pavucontrol true gammastep
grep -Fqx -- '--setenv=SWAY_NOIR_LID_AC_ACTION=lock' "$LID_LOG.systemd-run" ||
    fail 'charger lid action was not passed to the session'
grep -Fqx -- '--setenv=SWAY_NOIR_LID_BATTERY_ACTION=suspend' "$LID_LOG.systemd-run" ||
    fail 'battery lid action was not passed to the session'
tail -n 3 "$LID_LOG.systemd-run" | tr '\n' ' ' | grep -Fq 'lock-screen true gammastep' ||
    fail 'lid options shifted the positional session commands'

# Shipped defaults and bindings; the lock command keeps its quoted profile path.
grep -Fqx 'set $lid_ac_action system' "$repo_root/sway/config" || fail 'charger lid default changed'
grep -Fqx 'set $lid_battery_action system' "$repo_root/sway/config" || fail 'battery lid default changed'
binding="$(grep -F 'bindswitch --locked lid:on exec ' "$repo_root/sway/config.d/99-startup.conf")" ||
    fail 'lid close binding is missing'
grep -Fq 'bindswitch --locked lid:off exec ' "$repo_root/sway/config.d/99-startup.conf" ||
    fail 'lid open binding is missing'
command="${binding#*lid:on exec }"
command="${command//\$lid_ac_action/lock}"
command="${command//\$lid_battery_action/suspend}"
command="${command//\$lock_command/\"\$SWAY_NOIR_DIR/session/lock\"}"
install -m 755 "$mock_bin/lock" "$profile/session/lock"
logind OnExternalPower true
logind LidClosed false
: > "$LID_LOG"
SWAY_NOIR_DIR="$profile" sh -c "$command"
expect_log $'lock \nswaymsg -q output * power off' 'binding did not pass the lock command intact'

printf 'PASS: lid actions by power source, unplug watcher, inhibitor, validation and option passing\n'
