#!/usr/bin/bash
# Sway configuration and generated mock scripts intentionally contain literals.
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp_base="${TMPDIR:-/tmp}"
if [[ -z "${TMPDIR:-}" && -w /tmp/opencode ]]; then temp_base=/tmp/opencode; fi
test_root="$(mktemp -d "$temp_base/sway-noir-test.XXXXXX")"
readonly repo_root test_root
readonly mock_bin="$test_root/bin"
readonly test_home="$test_root/home"
readonly test_config="$test_home/config"
readonly test_state="$test_home/state"

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
while IFS='|' read -r scope check capability _; do
    [[ ( "$check" == command || "$check" == polkit ) && "$scope" != dark ]] || continue
    case "$capability" in systemctl|systemd-run|systemd-analyze) continue ;; esac
    ln -s "$(type -P true)" "$mock_bin/$capability"
done < "$repo_root/dependencies.list"
ln -s "$(type -P true)" "$mock_bin/systemctl"

cat > "$mock_bin/systemd-run" <<'EOF'
#!/usr/bin/bash
printf 'systemd 254 (254.1)\n'
EOF
cat > "$mock_bin/systemd-analyze" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$PORTAL_UNIT_DIR"
EOF
# Avoid host fontconfig creating cache files inside no-change fixtures.
cat > "$mock_bin/fc-match" <<'EOF'
#!/usr/bin/bash
printf 'IBM Plex Sans\n'
EOF
chmod 755 "$mock_bin/systemd-run" "$mock_bin/systemd-analyze" "$mock_bin/fc-match"
export PORTAL_UNIT_DIR="$test_root/portal-units"
install -d "$PORTAL_UNIT_DIR"
for unit in xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr; do
    printf '[Unit]\nDescription=Mock portal\n' > "$PORTAL_UNIT_DIR/$unit.service"
done

export HOME="$test_home"
export XDG_CONFIG_HOME="$test_config"
export XDG_STATE_HOME="$test_state"
export PATH="$mock_bin:$PATH"

snapshot_tree() {
    find "$1" -printf '%y %p %l\n' | sort
    find "$1" -type f -exec sha256sum {} + | sort
}

for case_name in \
    config-root \
    profile-root \
    profile-directory \
    systemd-root \
    systemd-directory \
    portal-directory \
    backup-root \
    dangling-profile-directory \
    non-directory; do
    case_root="$test_root/$case_name"
    case_home="$case_root/home"
    case_config="$case_home/config"
    outside="$case_root/outside-profile"
    install -d "$outside"
    printf 'unrelated configuration\n' > "$outside/config"
    install -m 644 "$repo_root/systemd/user/sway-noir-session.target" \
        "$outside/sway-noir-session.target"
    install -m 644 "$repo_root/xdg-desktop-portal/sway-portals.conf" \
        "$outside/sway-portals.conf"
    case "$case_name" in
        config-root) target_path="$case_config" ;;
        profile-root) target_path="$case_config/sway-noir" ;;
        profile-directory|dangling-profile-directory|non-directory)
            target_path="$case_config/sway-noir/swaylock" ;;
        systemd-root) target_path="$case_config/systemd" ;;
        systemd-directory) target_path="$case_config/systemd/user" ;;
        portal-directory) target_path="$case_config/xdg-desktop-portal" ;;
        backup-root) target_path="$case_config/sway-setup-backups" ;;
    esac
    install -d "${target_path%/*}"
    case "$case_name" in
        dangling-profile-directory) ln -s "$outside/missing" "$target_path" ;;
        non-directory) printf 'not a directory\n' > "$target_path" ;;
        *) ln -s "$outside" "$target_path" ;;
    esac
    # An early managed file must survive a conflict discovered later as well.
    install -D -m 755 "$repo_root/start-sway-noir" \
        "$case_config/sway-noir/start-sway-noir"
    fixture_before="$(snapshot_tree "$case_root")"
    for operation in install uninstall; do
        # Backups are never accessed or removed during uninstallation.
        if [[ "$case_name" == backup-root && "$operation" == uninstall ]]; then
            continue
        fi
        if [[ "$operation" == install ]]; then
            options=(--profile-only)
        else
            options=(--uninstall --yes)
        fi
        case_log="$test_root/$case_name-$operation.log"
        if HOME="$case_home" XDG_CONFIG_HOME="$case_config" \
           "$repo_root/install.sh" "${options[@]}" > "$case_log" 2>&1; then
            fail "$operation accepted unsafe target directory: $case_name"
        fi
        grep -Eq '^Error: (Refusing symbolic link in target directory path:|Expected a directory but found another path type:)' \
            "$case_log" || fail "$operation failed for the wrong reason: $case_name"
        [[ "$(snapshot_tree "$case_root")" == "$fixture_before" ]] ||
            fail "$operation changed files despite unsafe target directory: $case_name"
    done
done

atomic_root="$test_root/atomic-home"
atomic_repo="$atomic_root/repo"
atomic_home="$atomic_root/home/test-user"
atomic_config="$atomic_home/config"
install -d "$atomic_repo" "$atomic_root/var/home/test-user" "$atomic_root/outside"
ln -s var/home "$atomic_root/home"
for path in install.sh dependencies.list start-sway-noir session sway swaylock waybar fuzzel mako gammastep systemd themes xdg-desktop-portal; do
    cp -a -- "$repo_root/$path" "$atomic_repo/"
done
# Model system redirects below a fixture root, never by changing the host /home.
sed -e "s@\"/home\"@\"$atomic_root/home\"@g" \
    -e "s@\"/var/home\"@\"$atomic_root/var/home\"@g" \
    "$repo_root/session/installer/paths.sh" > "$atomic_repo/session/installer/paths.sh"
if ! HOME="$atomic_home" XDG_CONFIG_HOME="$atomic_config" \
    "$atomic_repo/install.sh" --profile-only > "$test_root/atomic-home-install.log" 2>&1; then
    fail 'the standard Atomic home redirect blocked profile installation'
fi
assert_file "$atomic_root/var/home/test-user/config/sway-noir/start-sway-noir"
printf '\n# modified before update\n' >> "$atomic_config/sway-noir/mako/config"
HOME="$atomic_home" XDG_CONFIG_HOME="$atomic_config" \
    "$atomic_repo/install.sh" --profile-only > "$test_root/atomic-home-update.log" 2>&1
atomic_backup="$(find "$atomic_config/sway-setup-backups" \
    -path '*/sway-noir/mako/config' -type f -print -quit)"
assert_file "$atomic_backup"
HOME="$atomic_home" XDG_CONFIG_HOME="$atomic_config" \
    "$atomic_repo/install.sh" --uninstall --yes > "$test_root/atomic-home-uninstall.log" 2>&1
[[ ! -e "$atomic_config/sway-noir/start-sway-noir" ]] || fail 'Atomic home uninstall left managed files'
assert_file "$atomic_config/sway-noir/sway/config.d/99-local.conf"
assert_file "$atomic_backup"

# The exception is for the exact system redirect, not links below or beyond it.
for case_name in unexpected-home-redirect linked-home-destination linked-home-config; do
    case "$case_name" in
        unexpected-home-redirect)
            rm -- "$atomic_root/home"
            ln -s outside "$atomic_root/home"
            ;;
        linked-home-destination)
            mv -- "$atomic_root/var/home" "$atomic_root/var/saved-home"
            ln -s ../outside "$atomic_root/var/home"
            ;;
        linked-home-config)
            mv -- "$atomic_config" "$atomic_home/saved-config"
            ln -s "$atomic_root/outside" "$atomic_config"
            ;;
    esac
    fixture_before="$(snapshot_tree "$atomic_root")"
    for operation in install uninstall; do
        if [[ "$operation" == install ]]; then options=(--profile-only); else options=(--uninstall --yes); fi
        case_log="$test_root/$case_name-$operation.log"
        if HOME="$atomic_home" XDG_CONFIG_HOME="$atomic_config" \
            "$atomic_repo/install.sh" "${options[@]}" > "$case_log" 2>&1; then
            fail "$operation accepted an unsafe Atomic home path: $case_name"
        fi
        grep -Fq 'Refusing symbolic link in target directory path:' "$case_log" ||
            fail "$operation failed for the wrong reason: $case_name"
        [[ "$(snapshot_tree "$atomic_root")" == "$fixture_before" ]] ||
            fail "$operation changed files despite unsafe Atomic home path: $case_name"
    done
    case "$case_name" in
        unexpected-home-redirect)
            rm -- "$atomic_root/home"
            ln -s var/home "$atomic_root/home"
            ;;
        linked-home-destination)
            rm -- "$atomic_root/var/home"
            mv -- "$atomic_root/var/saved-home" "$atomic_root/var/home"
            ;;
    esac
done

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
HOME="$portal_conflict_home" XDG_CONFIG_HOME="$portal_conflict_config" \
    "$repo_root/install.sh" --profile-only > "$test_root/portal-conflict.log" 2>&1
[[ "$(sha256sum < "$portal_conflict_target")" == "$portal_conflict_hash" ]] ||
    fail 'the unmanaged portal configuration was changed'
assert_file "$portal_conflict_config/sway-noir/start-sway-noir"

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

personal_config="$test_root/personal.conf"
install -D -m 644 "$repo_root/sway/config.d/99-local.conf.example" "$personal_config"
install -d "$test_config/sway-noir/sway/config.d"
ln -s "$personal_config" "$test_config/sway-noir/sway/config.d/99-local.conf"

"$repo_root/install.sh" --profile-only > "$test_root/install.log" 2>&1

assert_file "$test_config/sway-noir/start-sway-noir"
[[ ! -e "$test_config/sway-noir/session/installer" ]] || fail 'installer-only modules leaked into the desktop profile'
[[ -x "$test_config/sway-noir/session/screenshot" ]] || fail 'screenshot helper was not installed executable'
[[ -x "$test_config/sway-noir/session/theme" && -x "$test_config/sway-noir/session/lock-screen" ]] ||
    fail 'theme/lock helpers were not installed executable'
assert_file "$test_config/sway-noir/themes/rain/theme.conf"
assert_file "$test_config/sway-noir/themes/retro/waybar/style.css"
for component in theme.conf waybar/config.jsonc waybar/style.css fuzzel/fuzzel.ini swaylock/config; do
    assert_same "$repo_root/themes/praxis/$component" "$test_config/sway-noir/themes/praxis/$component"
done
for image in wallpaper.png lock-screen.png; do
    assert_same "$repo_root/themes/retro/$image" "$test_config/sway-noir/themes/retro/$image"
    assert_same "$repo_root/themes/praxis/$image" "$test_config/sway-noir/themes/praxis/$image"
done
install -d "$test_config/sway-noir/themes/personal"
"$test_config/sway-noir/session/theme" set praxis --no-reload > /dev/null
[[ "$(< "$test_state/sway-noir/current/theme-id")" == praxis ]] || fail 'installed Praxis theme could not be selected'
grep -Fqx "image=$test_config/sway-noir/themes/praxis/lock-screen.png" \
    "$test_state/sway-noir/current/swaylock/config" || fail 'installed Praxis lock image path is incorrect'
printf 'name=Personal Rain\n' > "$test_config/sway-noir/themes/personal/theme.conf"
"$test_config/sway-noir/session/theme" set retro --no-reload > /dev/null
assert_file "$test_config/sway-noir/.installed-files.sha256"
assert_file "$test_config/sway-noir/sway/config.d/99-local.conf"
assert_same "$repo_root/mako/config" "$test_config/sway-noir/mako/config"

# Equal contents must not hide damaged executable or configuration permissions.
profile_executables=(start-sway-noir session/start-session session/run-apps session/screenshot
    session/optional-command session/polkit-agent session/theme session/lock-screen)
for relative_path in "${profile_executables[@]}"; do
    chmod 644 "$test_config/sway-noir/$relative_path"
done
chmod 755 "$test_config/sway-noir/mako/config" \
    "$test_config/systemd/user/sway-noir-session.target"
chmod 600 "$personal_config"
"$repo_root/install.sh" --profile-only > "$test_root/mode-repair.log" 2>&1
for relative_path in "${profile_executables[@]}"; do
    [[ "$(stat -c '%a' "$test_config/sway-noir/$relative_path")" == 755 ]] ||
        fail "update did not repair executable permissions: $relative_path"
done
for target_path in "$test_config/sway-noir/mako/config" \
    "$test_config/systemd/user/sway-noir-session.target"; do
    [[ "$(stat -c '%a' "$target_path")" == 644 ]] ||
        fail "update did not repair configuration permissions: $target_path"
done
[[ "$(stat -c '%a' "$personal_config")" == 600 ]] || fail 'mode repair changed personal configuration permissions'
backups_before="$(find "$test_config/sway-setup-backups" -type f | sort)"
"$repo_root/install.sh" --profile-only > "$test_root/mode-repair-repeat.log" 2>&1
[[ "$(find "$test_config/sway-setup-backups" -type f | sort)" == "$backups_before" ]] ||
    fail 'an unchanged reinstall created unnecessary file backups'

# slurp is optional, and neither screenshot mode requires clipboard tools.
# Use a closed PATH so host-installed optional tools cannot hide regressions.
optional_bin="$test_root/optional-bin"
cp -a -- "$mock_bin" "$optional_bin"
rm -- "$optional_bin/slurp"
for command_name in chmod date dirname find findmnt grep head install mktemp mv readlink rm rmdir sha256sum sort stat; do
    ln -s "$(type -P "$command_name")" "$optional_bin/$command_name"
done
optional_home="$test_root/optional-home"
optional_config="$optional_home/config"
HOME="$optional_home" XDG_CONFIG_HOME="$optional_config" PATH="$optional_bin" \
    "$repo_root/install.sh" --profile-only > "$test_root/optional.log" 2>&1
[[ -x "$optional_config/sway-noir/session/screenshot" ]] || fail 'missing slurp blocked installation'
grep -Fq 'Optional command not found: slurp.' "$test_root/optional.log" ||
    fail 'missing optional region selector was not reported'
if [[ -f "$test_config/xdg-desktop-portal/sway-portals.conf" ]]; then
    assert_same "$repo_root/xdg-desktop-portal/sway-portals.conf" \
        "$test_config/xdg-desktop-portal/sway-portals.conf"
fi
grep -Fqx 'bindsym $mod+Shift+x exec $lock_command' \
    "$repo_root/sway/config.d/60-keybindings.conf" ||
    fail 'manual locking does not use the shared lock command'
grep -Fqx 'exec "$SWAY_NOIR_DIR/session/start-session" "$lock_command" "$audio_settings_command" "$polkit_agent_command" $gammastep_command' \
    "$repo_root/sway/config.d/99-startup.conf" ||
    fail 'session startup does not pass the shared lock command'
grep -Fqx 'bindsym XF86AudioMicMute exec $audio_command set-mute @DEFAULT_AUDIO_SOURCE@ toggle' \
    "$repo_root/sway/config.d/60-keybindings.conf" ||
    fail 'microphone mute binding is not disabled while the session is locked'
if grep -Fq 'bindsym --locked XF86AudioMicMute' \
   "$repo_root/sway/config.d/60-keybindings.conf"; then
    fail 'microphone mute binding remains active while the session is locked'
fi

printf '\n# changed by installer test\n' >> "$test_config/sway-noir/mako/config"
# A retired bundled theme is identified by its old manifest, not its name.
retired="$test_config/sway-noir/themes/retired"
customized="$test_config/sway-noir/themes/customized"
linked="$test_config/sway-noir/themes/linked"
install -d "$retired/waybar" "$customized" "$linked"
printf 'name=Retired\n' > "$retired/theme.conf"
printf '/* old style */\n' > "$retired/waybar/style.css"
printf 'name=Customized\n' > "$customized/theme.conf"
printf 'name=Linked\n' > "$linked/theme.conf"
printf 'outside profile\n' > "$test_config/outside.txt"
(
    cd "$test_config/sway-noir"
    sha256sum themes/retired/theme.conf themes/retired/waybar/style.css \
        themes/customized/theme.conf themes/linked/theme.conf themes/../../outside.txt
) >> "$test_config/sway-noir/.installed-files.sha256"
printf '# personal change\n' >> "$customized/theme.conf"
rm -- "$linked/theme.conf"
ln -s "$repo_root/themes/rain/theme.conf" "$linked/theme.conf"
"$repo_root/install.sh" --profile-only > "$test_root/update.log" 2>&1

assert_same "$repo_root/mako/config" "$test_config/sway-noir/mako/config"
backup_file="$(find "$test_config/sway-setup-backups" \
    -path '*/sway-noir/mako/config' -type f -print -quit)"
assert_file "$backup_file"
[[ ! -e "$retired" ]] || fail 'retired bundled theme remained selectable after update'
retired_backup="$(find "$test_config/sway-setup-backups" \
    -path '*/sway-noir/themes/retired/theme.conf' -type f -print -quit)"
assert_file "$retired_backup"
grep -Fqx 'name=Retired' "$retired_backup" || fail 'retired theme was not backed up'
assert_file "$customized/theme.conf"
[[ -L "$linked/theme.conf" ]] || fail 'obsolete theme symlink was removed'
assert_file "$test_config/outside.txt"
assert_file "$test_config/sway-noir/themes/personal/theme.conf"
[[ "$(< "$test_state/sway-noir/current/theme-id")" == retro ]] ||
    fail 'update changed the saved design'

# Update a previously installed default theme to its new name and ID.
(
    export HOME="$test_root/theme-rename-home"
    export XDG_CONFIG_HOME="$HOME/config"
    export XDG_STATE_HOME="$HOME/state"
    "$repo_root/install.sh" --profile-only > "$test_root/theme-rename-install.log" 2>&1
    old_theme="$XDG_CONFIG_HOME/sway-noir/themes/noir/theme.conf"
    install -D -m 644 /dev/null "$old_theme"
    printf 'name=Noir\n' > "$old_theme"
    (
        cd "$XDG_CONFIG_HOME/sway-noir"
        sha256sum themes/noir/theme.conf
    ) >> "$XDG_CONFIG_HOME/sway-noir/.installed-files.sha256"
    theme_command="$XDG_CONFIG_HOME/sway-noir/session/theme"
    "$theme_command" init > /dev/null
    printf 'noir\n' > "$XDG_STATE_HOME/sway-noir/current/theme-id"
    "$repo_root/install.sh" --profile-only > "$test_root/theme-rename-update.log" 2>&1
    [[ ! -e "${old_theme%/*}" ]] || fail 'old default theme remained selectable'
    [[ "$("$theme_command" current)" == rain ]] || fail 'saved default selection did not migrate'
    "$theme_command" init > /dev/null
    [[ "$(< "$XDG_STATE_HOME/sway-noir/current/theme-id")" == rain ]] ||
        fail 'migrated theme ID was not persisted at session startup'
)

printf '\n# keep my changes\n' >> "$test_config/sway-noir/mako/config"
modified_hash="$(sha256sum < "$test_config/sway-noir/mako/config")"
rm -- "$test_config/sway-noir/fuzzel/fuzzel.ini"
ln -s "$repo_root/fuzzel/fuzzel.ini" "$test_config/sway-noir/fuzzel/fuzzel.ini"
rm -- "$test_config/sway-noir/gammastep/config.ini"
ln -s "$test_root/nonexistent" "$test_config/sway-noir/gammastep/config.ini"
printf 'personal file\n' > "$test_config/sway-noir/personal.conf"

"$repo_root/install.sh" --uninstall --yes > "$test_root/uninstall.log" 2>&1

assert_file "$test_config/sway-noir/sway/config.d/99-local.conf"
assert_file "$backup_file"
[[ -L "$test_config/sway-noir/sway/config.d/99-local.conf" ]] ||
    fail 'the preserved local configuration symbolic link was changed'
assert_same "$repo_root/sway/config.d/99-local.conf.example" "$personal_config"
[[ ! -e "$test_config/sway-noir/start-sway-noir" ]] || fail 'unchanged profile file remained'
assert_file "$test_config/sway-noir/.installed-files.sha256"
[[ "$(sha256sum < "$test_config/sway-noir/mako/config")" == "$modified_hash" ]] ||
    fail 'modified profile file was not preserved'
[[ -L "$test_config/sway-noir/fuzzel/fuzzel.ini" ]] || fail 'symbolic link was removed'
[[ -L "$test_config/sway-noir/gammastep/config.ini" ]] || fail 'dangling symbolic link was removed'
assert_file "$test_config/sway-noir/personal.conf"
assert_file "$test_config/sway-noir/themes/personal/theme.conf"
[[ "$(< "$test_state/sway-noir/current/theme-id")" == retro ]] ||
    fail 'uninstall removed the saved design'
[[ ! -e "$test_config/sway-noir/themes/retro" ]] || fail 'empty bundled theme directory remained'
[[ ! -e "$test_config/sway-noir/themes/praxis" ]] || fail 'empty Praxis theme directory remained'
grep -Fq "Preserving modified or unverified profile file: $test_config/sway-noir/mako/config" \
    "$test_root/uninstall.log" || fail 'modified file was not reported'
grep -Fq "Preserving symbolic link: $test_config/sway-noir/fuzzel/fuzzel.ini" \
    "$test_root/uninstall.log" || fail 'symbolic link was not reported'

# The removal baseline is the installed release, not the current checkout.
release_dir="$test_root/release with spaces"
install -d "$release_dir"
for path in install.sh dependencies.list start-sway-noir session sway swaylock waybar fuzzel mako gammastep systemd themes xdg-desktop-portal; do
    cp -a -- "$repo_root/$path" "$release_dir/"
done
release_home="$test_root/release-home"
release_config="$release_home/config"
HOME="$release_home" XDG_CONFIG_HOME="$release_config" \
    "$release_dir/install.sh" --profile-only > "$test_root/release-install.log" 2>&1
printf '\n# a later release\n' >> "$release_dir/mako/config"
printf '\n# a later integration release\n' >> "$release_dir/systemd/user/sway-noir-session.target"
HOME="$release_home" XDG_CONFIG_HOME="$release_config" \
    "$release_dir/install.sh" --uninstall --yes > "$test_root/release-uninstall.log" 2>&1
[[ ! -e "$release_config/sway-noir/mako/config" ]] ||
    fail 'unchanged installed file was compared against the newer checkout'
[[ ! -e "$release_config/systemd/user/sway-noir-session.target" ]] ||
    fail 'unchanged installed integration was compared against the newer checkout'
[[ ! -e "$release_config/sway-noir/.installed-files.sha256" ]] ||
    fail 'manifest remained after removing all known profile files'

# Keep the original baseline for repeated uninstalls, even when a modified file
# happens to match the newer checkout.
HOME="$release_home" XDG_CONFIG_HOME="$release_config" \
    "$release_dir/install.sh" --profile-only > "$test_root/repeat-install.log" 2>&1
printf '\n# user change also present in a later checkout\n' >> "$release_dir/mako/config"
cp -- "$release_dir/mako/config" "$release_config/sway-noir/mako/config"
for _ in 1 2; do
    HOME="$release_home" XDG_CONFIG_HOME="$release_config" \
        "$release_dir/install.sh" --uninstall --yes > "$test_root/repeat-uninstall.log" 2>&1
    assert_file "$release_config/sway-noir/mako/config"
done

# Legacy installs without a manifest err on the side of preserving files.
rm -- "$legacy_config/sway-noir/.installed-files.sha256"
printf '\n# legacy customization\n' >> "$legacy_config/sway-noir/mako/config"
HOME="$legacy_home" XDG_CONFIG_HOME="$legacy_config" \
    "$repo_root/install.sh" --uninstall --yes > "$test_root/legacy-uninstall.log" 2>&1
assert_file "$legacy_config/sway-noir/mako/config"
[[ ! -e "$legacy_config/sway-noir/start-sway-noir" ]] ||
    fail 'unchanged legacy profile file remained'

# A manifest symlink must not be followed or authorize removals.
manifest_home="$test_root/manifest-home"
manifest_config="$manifest_home/config"
manifest="$manifest_config/sway-noir/.installed-files.sha256"
install -D "$repo_root/mako/config" "$manifest_config/sway-noir/mako/config"
ln -s "$test_root/nonexistent-manifest" "$manifest"
HOME="$manifest_home" XDG_CONFIG_HOME="$manifest_config" \
    "$repo_root/install.sh" --uninstall --yes > "$test_root/manifest-uninstall.log" 2>&1
assert_file "$manifest_config/sway-noir/mako/config"
[[ -L "$manifest" ]] || fail 'unmanaged manifest symlink was removed'
if HOME="$manifest_home" XDG_CONFIG_HOME="$manifest_config" \
    "$repo_root/install.sh" --profile-only > "$test_root/manifest-install.log" 2>&1; then
    fail 'installer replaced an unmanaged manifest symlink'
fi
[[ ! -e "$manifest_config/sway-noir/start-sway-noir" ]] ||
    fail 'files changed before rejecting the manifest symlink'

for manifest_contents in incomplete invalid; do
    unsafe_home="$test_root/$manifest_contents-home"
    unsafe_config="$unsafe_home/config"
    unsafe_manifest="$unsafe_config/sway-noir/.installed-files.sha256"
    install -D "$repo_root/mako/config" "$unsafe_config/sway-noir/mako/config"
    printf '# Managed by Sway Noir.\n' > "$unsafe_manifest"
    if [[ "$manifest_contents" == invalid ]]; then
        printf 'invalid-checksum  mako/config\n' >> "$unsafe_manifest"
    fi
    HOME="$unsafe_home" XDG_CONFIG_HOME="$unsafe_config" \
        "$repo_root/install.sh" --uninstall --yes > "$test_root/$manifest_contents-uninstall.log" 2>&1
    assert_file "$unsafe_config/sway-noir/mako/config"
done

linked_home="$test_root/linked-home"
linked_config="$linked_home/config"
linked_profile="$test_root/linked-profile"
install -D "$repo_root/mako/config" "$linked_profile/mako/config"
install -d "$linked_profile/waybar" "$linked_config"
ln -s "$linked_profile" "$linked_config/sway-noir"
if HOME="$linked_home" XDG_CONFIG_HOME="$linked_config" \
   "$repo_root/install.sh" --uninstall --yes > "$test_root/linked-uninstall.log" 2>&1; then
    fail 'uninstall accepted a linked profile directory'
fi
grep -Fq 'Refusing symbolic link in target directory path:' "$test_root/linked-uninstall.log" ||
    fail 'uninstall did not report the linked profile directory'
assert_file "$linked_profile/mako/config"
[[ -L "$linked_config/sway-noir" && -d "$linked_profile/waybar" ]] ||
    fail 'uninstall traversed a linked profile directory'

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
swayidle_mock="$session_mock_bin/swayidle"
{
    printf '#!/usr/bin/bash\n'
    printf 'printf "swayidle %%s\\n" "$*" >> "$SESSION_LOG"\n'
} > "$swayidle_mock"
chmod 755 "$swayidle_mock"
systemctl_mock="$session_mock_bin/systemctl"
{
    printf '#!/usr/bin/bash\n'
    printf 'if [[ " $* " == *" xdg-desktop-portal"* ]]; then exit 1; fi\n'
    printf 'exit 0\n'
} > "$systemctl_mock"
chmod 755 "$systemctl_mock"

systemd_run_mock="$session_mock_bin/systemd-run"
{
    printf '#!/usr/bin/bash\n'
    printf 'printf "systemd-run %%s\\n" "$*" >> "$SESSION_LOG"\n'
    printf 'while [[ "${1:-}" == --* ]]; do shift; done\n'
    printf 'exec "$@"\n'
} > "$systemd_run_mock"
chmod 755 "$systemd_run_mock"
install -D -m 755 "$repo_root/session/run-apps" "$test_config/sway-noir/session/run-apps"

SESSION_LOG="$session_log" SWAY_NOIR_SESSION_ID=1-2-3 PATH="$session_mock_bin:$PATH" \
    "$repo_root/session/start-session" 'lock-screen --ready' pavucontrol true gammastep \
    > "$test_root/session.out" 2> "$test_root/session.err"
for _ in {1..20}; do
    if [[ -f "$session_log" ]] &&
       [[ "$(wc -l < "$session_log")" -ge 4 ]]; then
        break
    fi
    sleep 0.05
done
for command_name in waybar mako gammastep; do
    grep -Fqx "$command_name" "$session_log" ||
        fail "$command_name was blocked by a desktop portal failure"
done
[[ "$(grep -Fxc 'swayidle -w before-sleep lock-screen --ready' "$session_log")" == 1 ]] ||
    fail 'swayidle was not started exactly once with only the before-sleep lock command'
grep -Fq -- '--unit=sway-noir-apps-1-2-3.service --property=PartOf=sway-noir-session.target --property=After=sway-noir-session.target' \
    "$session_log" || fail 'desktop processes are not bound to their session target'

printf 'PASS: directory safety, slurp dependency, preflight, conflicts, legacy update, install, update backup, uninstall and resilient session startup with suspend locking\n'
