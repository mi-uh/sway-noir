#!/usr/bin/bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
readonly repo_root test_root
readonly fixture="$test_root/repo"
readonly mock_bin="$test_root/bin"

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_same() {
    [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]] ||
        fail "files differ: $1 and $2"
}

install -d "$fixture" "$mock_bin"
for path in dependencies.list start-sway-noir sway swaylock waybar fuzzel mako gammastep systemd xdg-desktop-portal; do
    ln -s "$repo_root/$path" "$fixture/$path"
done
cp -a "$repo_root/themes" "$fixture/themes"
cp -a "$repo_root/session" "$fixture/session"
install -m 755 "$repo_root/install.sh" "$fixture/install.sh"
# Isolate the two build-time portal search roots as well as the XDG paths.
# No host portal files or systemd services are read or changed by these tests.
sed -e "s@\"/etc\"@\"$test_root/system-config\"@g" \
    -e "s@\"/usr/share\"@\"$test_root/system-data\"@g" \
    "$repo_root/session/installer/integrations.sh" > "$fixture/session/installer/integrations.sh"
for command_name in brightnessctl dbus-update-activation-environment foot fuzzel gammastep \
    grim mako makoctl wpctl pavucontrol playerctl sway swaybg swayidle swaylock swaymsg swaynag systemctl waybar; do
    ln -s "$(type -P true)" "$mock_bin/$command_name"
done
cat > "$mock_bin/systemd-run" <<'EOF'
#!/usr/bin/bash
printf 'systemd 254 (254.1)\n'
EOF
cat > "$mock_bin/systemd-analyze" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$PORTAL_UNIT_DIR"
EOF
chmod 755 "$mock_bin/systemd-run" "$mock_bin/systemd-analyze"
export PORTAL_UNIT_DIR="$test_root/portal-units"
install -d "$PORTAL_UNIT_DIR"
for unit in xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr; do
    printf '[Unit]\nDescription=Mock portal\n' > "$PORTAL_UNIT_DIR/$unit.service"
done
export PATH="$mock_bin:$PATH"

new_case() {
    case_root="$test_root/$1"
    export HOME="$case_root/home with spaces"
    export XDG_CONFIG_HOME="$HOME/config"
    export XDG_CONFIG_DIRS="$case_root/etc-xdg"
    export XDG_DATA_HOME="$HOME/data"
    export XDG_DATA_DIRS="$case_root/local-share:$case_root/share"
    target="$XDG_CONFIG_HOME/xdg-desktop-portal/sway-portals.conf"
    vendor="$case_root/share/xdg-desktop-portal/sway-portals.conf"
    install_log="$case_root/install.log"
    uninstall_log="$case_root/uninstall.log"
    install -d "$case_root"
}

install_profile() {
    if ! "$fixture/install.sh" --profile-only > "$install_log" 2>&1; then
        cat "$install_log" >&2
        fail 'profile installation failed'
    fi
}

uninstall_profile() {
    if ! "$fixture/install.sh" --uninstall --yes > "$uninstall_log" 2>&1; then
        cat "$uninstall_log" >&2
        fail 'profile uninstallation failed'
    fi
}

write_vendor() {
    install -D -m 644 "$repo_root/xdg-desktop-portal/sway-portals.conf" "$vendor"
}

new_case fallback
install_profile
assert_same "$repo_root/xdg-desktop-portal/sway-portals.conf" "$target"
grep -Fqx 'org.freedesktop.impl.portal.Inhibit=none' "$target" || fail 'fallback lacks Inhibit=none'
uninstall_profile
[[ ! -e "$target" ]] || fail 'unchanged managed fallback was not removed'

new_case vendor
write_vendor
vendor_hash="$(sha256sum < "$vendor")"
install_profile
[[ ! -e "$target" && ! -L "$target" ]] || fail 'vendor configuration was overridden'
grep -Fq "not installed; use $vendor" "$install_log" || fail 'vendor choice was not reported'
uninstall_profile
[[ "$(sha256sum < "$vendor")" == "$vendor_hash" ]] || fail 'vendor configuration was changed'

new_case config-precedence
write_vendor
admin_config="$XDG_CONFIG_DIRS/xdg-desktop-portal/sway-portals.conf"
install -D -m 644 "$vendor" "$admin_config"
install_profile
grep -Fq "not installed; use $admin_config" "$install_log" || fail 'system configuration precedence was ignored'
[[ ! -e "$target" ]] || fail 'system administrator configuration was overridden'

new_case generic-user
generic="$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf"
install -D -m 644 /dev/null "$generic"
printf '[preferred]\ndefault=my-backend\n' > "$generic"
generic_hash="$(sha256sum < "$generic")"
install_profile
[[ ! -e "$target" ]] || fail 'explicit generic user configuration was masked'
uninstall_profile
[[ "$(sha256sum < "$generic")" == "$generic_hash" ]] || fail 'generic user configuration was changed'

new_case invalid-vendor
install -D -m 644 /dev/null "$vendor"
printf 'not a portal configuration\n' > "$vendor"
install_profile
assert_same "$repo_root/xdg-desktop-portal/sway-portals.conf" "$target"

for vendor_present in yes no; do
    new_case "custom-$vendor_present"
    [[ "$vendor_present" != yes ]] || write_vendor
    install -D -m 644 /dev/null "$target"
    printf '[preferred]\ndefault=custom\n' > "$target"
    custom_hash="$(sha256sum < "$target")"
    install_profile
    [[ -f "$XDG_CONFIG_HOME/sway-noir/start-sway-noir" ]] || fail 'custom portal blocked installation'
    [[ "$(sha256sum < "$target")" == "$custom_hash" ]] || fail 'custom user portal was replaced'
    uninstall_profile
    [[ "$(sha256sum < "$target")" == "$custom_hash" ]] || fail 'custom user portal was removed'

    new_case "modified-managed-$vendor_present"
    [[ "$vendor_present" != yes ]] || write_vendor
    install -D -m 644 "$repo_root/xdg-desktop-portal/sway-portals.conf" "$target"
    printf '\n# keep my customization\n' >> "$target"
    custom_hash="$(sha256sum < "$target")"
    install_profile
    [[ "$(sha256sum < "$target")" == "$custom_hash" ]] || fail 'modified managed fallback was replaced'
    uninstall_profile
    [[ "$(sha256sum < "$target")" == "$custom_hash" ]] || fail 'marker alone authorized removal'
done

for kind in valid dangling directory; do
    new_case "conflict-$kind"
    write_vendor
    install -d "$(dirname -- "$target")"
    case "$kind" in
        valid) ln -s "$vendor" "$target" ;;
        dangling) ln -s "$case_root/nonexistent" "$target" ;;
        directory) install -d "$target" ;;
    esac
    install_profile
    uninstall_profile
    if [[ "$kind" == directory ]]; then
        [[ -d "$target" ]] || fail 'portal directory conflict was removed'
    else
        [[ -L "$target" ]] || fail 'portal symbolic link was removed'
    fi
done

# Both the previous fallback and the current managed fallback migrate to vendor
# defaults, with an exact backup before removal and no changes to vendor files.
for version in legacy current; do
    new_case "migration-$version"
    write_vendor
    install -D -m 644 "$repo_root/xdg-desktop-portal/sway-portals.conf" "$case_root/expected"
    if [[ "$version" == legacy ]]; then
        grep -Fvx 'org.freedesktop.impl.portal.Inhibit=none' "$case_root/expected" > "$case_root/legacy"
        mv -- "$case_root/legacy" "$case_root/expected"
    fi
    install -D -m 644 "$case_root/expected" "$target"
    install_profile
    [[ ! -e "$target" ]] || fail "$version managed override was not migrated"
    backup="$(find "$XDG_CONFIG_HOME/sway-setup-backups" -path '*/xdg-desktop-portal/sway-portals.conf' -print -quit)"
    [[ -f "$backup" ]] || fail 'migrated portal override was not backed up'
    assert_same "$case_root/expected" "$backup"
    assert_same "$repo_root/xdg-desktop-portal/sway-portals.conf" "$vendor"
    install_profile
    [[ ! -e "$target" ]] || fail 'second installation restored an unnecessary override'
done

new_case fallback-upgrade
install -d "$(dirname -- "$target")"
grep -Fvx 'org.freedesktop.impl.portal.Inhibit=none' \
    "$repo_root/xdg-desktop-portal/sway-portals.conf" > "$target"
cp -- "$target" "$case_root/expected"
install_profile
assert_same "$repo_root/xdg-desktop-portal/sway-portals.conf" "$target"
backup="$(find "$XDG_CONFIG_HOME/sway-setup-backups" -path '*/xdg-desktop-portal/sway-portals.conf' -print -quit)"
assert_same "$case_root/expected" "$backup"

new_case blocked-migration
write_vendor
install -D -m 644 "$repo_root/xdg-desktop-portal/sway-portals.conf" "$target"
install -D -m 644 /dev/null "$XDG_CONFIG_HOME/systemd/user/sway-noir-session.target"
if "$fixture/install.sh" --profile-only > "$install_log" 2>&1; then
    fail 'unmanaged session target did not block installation'
fi
assert_same "$repo_root/xdg-desktop-portal/sway-portals.conf" "$target"
[[ ! -e "$XDG_CONFIG_HOME/sway-noir" ]] || fail 'blocked migration changed profile files'

printf 'PASS: portal fallback, vendor precedence, custom configurations, conflicts, migration, backups and uninstall\n'
