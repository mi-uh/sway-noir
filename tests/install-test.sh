#!/usr/bin/bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly test_root="$(mktemp -d)"
readonly mock_bin="$test_root/bin"
readonly test_home="$test_root/home"
readonly test_config="$test_home/config"
readonly conflict="$test_config/xdg-desktop-portal/sway-portals.conf"

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "expected file: $1"
}

assert_same() {
    local left_hash right_hash

    left_hash="$(sha256sum < "$1")"
    right_hash="$(sha256sum < "$2")"
    [[ "$left_hash" == "$right_hash" ]] ||
        fail "expected identical files: $1 and $2"
}

install -d -m 700 "$mock_bin"
for command_name in \
    brightnessctl \
    dbus-update-activation-environment \
    foot \
    fuzzel \
    gammastep \
    grim \
    mako \
    pactl \
    pavucontrol \
    playerctl \
    sway \
    swaybg \
    swaylock \
    systemctl \
    waybar; do
    ln -s "$(type -P true)" "$mock_bin/$command_name"
done

export HOME="$test_home"
export XDG_CONFIG_HOME="$test_config"
export PATH="$mock_bin:$PATH"

blocked_home="$test_root/blocked-home"
blocked_config="$blocked_home/config"
blocked_target="$blocked_config/systemd/user/sway-noir-session.target"
install -D -m 644 "$repo_root/README.md" "$blocked_target"
if HOME="$blocked_home" XDG_CONFIG_HOME="$blocked_config" \
   "$repo_root/install.sh" --profile-only > "$test_root/blocked.log" 2>&1; then
    fail 'an unmanaged required session target did not block installation'
fi
[[ ! -e "$blocked_config/sway-noir" ]] ||
    fail 'files changed despite a required integration conflict'

portal_conflict_home="$test_root/portal-conflict-home"
portal_conflict_config="$portal_conflict_home/config"
portal_conflict_target="$portal_conflict_config/xdg-desktop-portal/sway-portals.conf"
install -D -m 644 "$repo_root/README.md" "$portal_conflict_target"
portal_conflict_hash="$(sha256sum < "$portal_conflict_target")"
if HOME="$portal_conflict_home" XDG_CONFIG_HOME="$portal_conflict_config" \
   "$repo_root/install.sh" --profile-only > "$test_root/portal-conflict.log" 2>&1; then
    fail 'an unmanaged portal configuration did not block installation'
fi
[[ "$(sha256sum < "$portal_conflict_target")" == "$portal_conflict_hash" ]] ||
    fail 'the unmanaged portal configuration was changed'
[[ ! -e "$portal_conflict_config/sway-noir" ]] ||
    fail 'files changed despite a portal configuration conflict'

legacy_home="$test_root/legacy-home"
legacy_config="$legacy_home/config"
legacy_target="$legacy_config/systemd/user/sway-noir-session.target"
install -D -m 644 /dev/null "$legacy_target"
printf '%s\n' \
    '[Unit]' \
    'Description=Sway Noir graphical session' \
    'BindsTo=graphical-session.target' \
    'Wants=graphical-session-pre.target' \
    'After=graphical-session-pre.target' > "$legacy_target"
HOME="$legacy_home" XDG_CONFIG_HOME="$legacy_config" \
    "$repo_root/install.sh" --profile-only > "$test_root/legacy.log" 2>&1
assert_same "$repo_root/systemd/user/sway-noir-session.target" "$legacy_target"

"$repo_root/install.sh" --profile-only > "$test_root/install.log" 2>&1

assert_file "$test_config/sway-noir/start-sway-noir"
assert_file "$test_config/sway-noir/sway/config.d/99-local.conf"
assert_same "$repo_root/mako/config" "$test_config/sway-noir/mako/config"
assert_same "$repo_root/xdg-desktop-portal/sway-portals.conf" \
    "$test_config/xdg-desktop-portal/sway-portals.conf"

printf '\n# changed by installer test\n' >> "$test_config/sway-noir/mako/config"
"$repo_root/install.sh" --profile-only > "$test_root/update.log" 2>&1

assert_same "$repo_root/mako/config" "$test_config/sway-noir/mako/config"
backup_file="$(find "$test_config/sway-setup-backups" \
    -path '*/sway-noir/mako/config' -type f -print -quit)"
assert_file "$backup_file"

"$repo_root/install.sh" --uninstall --yes > "$test_root/uninstall.log" 2>&1

assert_file "$test_config/sway-noir/sway/config.d/99-local.conf"
assert_file "$backup_file"
if find "$test_config/sway-noir" -type f ! -name 99-local.conf -print -quit |
   grep -q .; then
    fail 'managed profile files remained after uninstall'
fi

session_mock_bin="$test_root/session-bin"
session_log="$test_root/session.log"
install -d -m 700 "$session_mock_bin"
ln -s "$(type -P true)" "$session_mock_bin/dbus-update-activation-environment"
for command_name in waybar mako gammastep; do
    command_path="$session_mock_bin/$command_name"
    {
        printf '#!/usr/bin/bash\n'
        printf 'printf "%%s\\n" "$(basename -- "$0")" >> "$SESSION_LOG"\n'
    } > "$command_path"
    chmod 755 "$command_path"
done
systemctl_mock="$session_mock_bin/systemctl"
{
    printf '#!/usr/bin/bash\n'
    printf 'if [[ " $* " == *" xdg-desktop-portal"* ]]; then exit 1; fi\n'
    printf 'exit 0\n'
} > "$systemctl_mock"
chmod 755 "$systemctl_mock"

SESSION_LOG="$session_log" PATH="$session_mock_bin:$PATH" \
    "$repo_root/session/start-session" gammastep \
    > "$test_root/session.out" 2> "$test_root/session.err"
for _ in {1..20}; do
    if [[ -f "$session_log" ]] &&
       [[ "$(wc -l < "$session_log")" -ge 3 ]]; then
        break
    fi
    sleep 0.05
done
for command_name in waybar mako gammastep; do
    grep -Fqx "$command_name" "$session_log" ||
        fail "$command_name was blocked by a desktop portal failure"
done

printf 'PASS: preflight, conflicts, legacy update, install, update backup, uninstall and resilient session startup\n'
