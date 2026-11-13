#!/usr/bin/bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
readonly repo_root test_root
readonly mock_bin="$test_root/bin"
launcher_pid=""

cleanup() {
    if [[ -n "$launcher_pid" ]]; then
        kill -TERM "$launcher_pid" 2>/dev/null || true
        wait "$launcher_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

install -d "$mock_bin" "$test_root/home/config/sway-noir/sway"
touch "$test_root/home/config/sway-noir/sway/config"
install -d "$test_root/home/config/sway-noir/session"
# shellcheck disable=SC2016
printf '#!/usr/bin/bash\n[[ "$1" == init ]]\n' > "$test_root/home/config/sway-noir/session/theme"
chmod 755 "$test_root/home/config/sway-noir/session/theme"

cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/bash
set -eu
printf '%s\n' "$*" >> "$SYSTEM_LOG"
case "$*" in
    '--user show-environment')
        [[ "${MOCK_FAIL_SHOW:-0}" == 0 ]] || exit 1
        cat "$MANAGER_ENV"
        ;;
    '--user stop '*|'--user unset-environment '*)
        [[ "${MOCK_FAIL_CLEANUP:-0}" == 0 ]] || exit 1
        ;;
esac
EOF

cat > "$mock_bin/dbus-update-activation-environment" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "$DBUS_LOG"
exit "${MOCK_FAIL_CLEANUP:-0}"
EOF

cat > "$mock_bin/sway" <<'EOF'
#!/usr/bin/bash
set -eu
printf '%s\n' "$SWAY_NOIR_SESSION_ID" > "$SESSION_ID_FILE"
case "$MOCK_MODE" in
    early) ;;
    newer) printf 'SWAY_NOIR_SESSION_ID=99-88-77\n' > "$MANAGER_ENV" ;;
    *) printf 'SWAY_NOIR_SESSION_ID=%s\nSWAYSOCK=/run/old-sway.sock\n' \
           "$SWAY_NOIR_SESSION_ID" > "$MANAGER_ENV" ;;
esac
if [[ "$MOCK_MODE" == signal ]]; then
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    touch "$READY_FILE"
    while true; do sleep 0.02; done
fi
exit "${MOCK_SWAY_STATUS:-0}"
EOF
chmod 755 "$mock_bin/systemctl" "$mock_bin/dbus-update-activation-environment" "$mock_bin/sway"
# Cover the distribution-provided launcher path without invoking host programs.
ln -s sway "$mock_bin/start-sway"

export HOME="$test_root/home"
export XDG_CONFIG_HOME="$HOME/config"
export PATH="$mock_bin:$PATH"
export SYSTEM_LOG="$test_root/system.log"
export DBUS_LOG="$test_root/dbus.log"
export MANAGER_ENV="$test_root/manager.env"
export SESSION_ID_FILE="$test_root/session-id"
export READY_FILE="$test_root/ready"

reset_logs() {
    : > "$SYSTEM_LOG"
    : > "$DBUS_LOG"
    : > "$MANAGER_ENV"
    rm -f -- "$READY_FILE"
}

assert_owned_cleanup() {
    local session_id
    session_id="$(cat "$SESSION_ID_FILE")"
    [[ "$(grep -Fxc -- "--user stop sway-noir-apps-$session_id.service" "$SYSTEM_LOG")" == 1 ]] ||
        fail 'the session-specific desktop unit was not stopped exactly once'
    [[ "$(grep -Fxc -- '--user stop sway-noir-session.target graphical-session.target' "$SYSTEM_LOG")" == 1 ]] ||
        fail 'graphical targets were not stopped exactly once'
    grep -Fqx -- '--user stop xdg-desktop-portal.service xdg-desktop-portal-gtk.service xdg-desktop-portal-wlr.service' \
        "$SYSTEM_LOG" || fail 'portal services were not stopped'
    grep -Fqx -- '--user unset-environment DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE SWAY_NOIR_SESSION_ID' \
        "$SYSTEM_LOG" || fail 'systemd activation values were not removed'
    grep -Fqx -- 'DISPLAY= WAYLAND_DISPLAY= SWAYSOCK= XDG_CURRENT_DESKTOP= XDG_SESSION_DESKTOP= XDG_SESSION_TYPE= SWAY_NOIR_SESSION_ID=' \
        "$DBUS_LOG" || fail 'D-Bus activation values were not emptied'
    if grep -Fq 'QT_QPA_PLATFORMTHEME' "$SYSTEM_LOG" "$DBUS_LOG"; then
        fail 'cleanup changed the user-wide Qt configuration'
    fi
}

for sway_status in 0 23; do
    reset_logs
    status=0
    MOCK_MODE=normal MOCK_SWAY_STATUS="$sway_status" "$repo_root/start-sway-noir" \
        > "$test_root/launcher.out" 2> "$test_root/launcher.err" || status=$?
    [[ "$status" == "$sway_status" ]] || fail 'Sway exit status was not preserved'
    assert_owned_cleanup
done

# Cleanup failures are warnings, and must not mask the compositor's status or
# prevent the remaining cleanup operations from being attempted.
reset_logs
status=0
MOCK_MODE=normal MOCK_SWAY_STATUS=42 MOCK_FAIL_CLEANUP=1 "$repo_root/start-sway-noir" \
    > "$test_root/failure.out" 2> "$test_root/failure.err" || status=$?
[[ "$status" == 42 ]] || fail 'cleanup failure masked the Sway exit status'
assert_owned_cleanup
grep -Fq 'Warning:' "$test_root/failure.err" || fail 'cleanup failure was not reported'

for mode in early newer; do
    reset_logs
    MOCK_MODE="$mode" "$repo_root/start-sway-noir" > "$test_root/$mode.out" 2> "$test_root/$mode.err"
    grep -Fq -- '--user stop sway-noir-apps-' "$SYSTEM_LOG" || fail 'own desktop unit was not stopped'
    if grep -Eq 'graphical-session.target|unset-environment|xdg-desktop-portal' "$SYSTEM_LOG" ||
       [[ -s "$DBUS_LOG" ]]; then
        fail 'cleanup changed a shared environment not owned by this session'
    fi
done

reset_logs
MOCK_MODE=normal MOCK_FAIL_SHOW=1 "$repo_root/start-sway-noir" \
    > "$test_root/manager.out" 2> "$test_root/manager.err"
grep -Fq 'skipping shared session cleanup' "$test_root/manager.err" ||
    fail 'unavailable environment ownership was not reported'
[[ ! -s "$DBUS_LOG" ]] || fail 'unconfirmed environment ownership was ignored'

for signal in TERM HUP; do
    reset_logs
    MOCK_MODE=signal "$repo_root/start-sway-noir" > "$test_root/signal.out" 2> "$test_root/signal.err" &
    launcher_pid=$!
    for _ in {1..100}; do
        [[ -f "$READY_FILE" ]] && break
        sleep 0.02
    done
    [[ -f "$READY_FILE" ]] || fail 'mock compositor did not start'
    kill -s "$signal" "$launcher_pid"
    status=0
    wait "$launcher_pid" || status=$?
    launcher_pid=""
    expected_status=143
    [[ "$signal" != HUP ]] || expected_status=129
    [[ "$status" == "$expected_status" ]] || fail "$signal was not forwarded to Sway"
    assert_owned_cleanup
done

printf 'PASS: normal and abnormal logout, signals, cleanup failures and shared environment ownership\n'
