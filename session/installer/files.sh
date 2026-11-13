#!/usr/bin/bash
# Single source of truth for managed files. Ordered ID lists select a scope;
# the associative registry holds each file's source, target, mode and policy.
# shellcheck disable=SC2034,SC2154

register_file() {
    local id="$1" scope="$2" source="$3" target="$4" mode="$5" conflict="$6" action="$7"

    [[ -z "${files[$id.source]:-}" ]] || die "Duplicate managed file ID: $id"
    case "$scope" in
        profile) profile_files+=("$id") ;;
        external) external_files+=("$id") ;;
        system) system_files+=("$id") ;;
        *) die "Unknown managed file scope: $scope" ;;
    esac
    files["$id.scope"]="$scope"
    files["$id.source"]="$source"
    files["$id.target"]="$target"
    files["$id.mode"]="$mode"
    files["$id.conflict"]="$conflict"
    files["$id.action"]="$action"
}

register_profile_file() {
    register_file "$1" profile "$1" "$profile_root/$1" "${2:-644}" replace install
}

register_login_file() {
    register_file "$1" system session/sway-noir.desktop "$2" 644 error preserve
    login_files+=("$1")
}

initialize_file_registry() {
    declare -gA files=()
    declare -ga profile_files=() external_files=() system_files=() login_files=()

    register_profile_file start-sway-noir 755
    register_profile_file session/start-session 755
    register_profile_file session/run-apps 755
    register_profile_file session/screenshot 755
    register_profile_file session/optional-command 755
    register_profile_file session/polkit-agent 755
    register_profile_file session/theme 755
    register_profile_file session/lock-screen 755
    register_profile_file session/dependencies.sh
    register_profile_file sway/config
    register_profile_file sway/config.d/20-outputs.conf
    register_profile_file sway/config.d/40-look.conf
    register_profile_file sway/config.d/50-input.conf
    register_profile_file sway/config.d/60-keybindings.conf
    register_profile_file sway/config.d/90-bar.conf
    register_profile_file sway/config.d/99-startup.conf
    register_profile_file sway/backgrounds/cozy-cyberpunk-room.png
    register_profile_file waybar/config.jsonc
    register_profile_file waybar/style.css
    register_profile_file fuzzel/fuzzel.ini
    register_profile_file mako/config
    register_profile_file gammastep/config.ini
    register_profile_file swaylock/config
    register_profile_file swaylock/cozy-cyberpunk-room-lock.png

    # Personal themes absent from the checkout remain untouched.
    local theme_file
    while IFS= read -r theme_file; do
        register_profile_file "${theme_file#"$setup_dir/"}"
    done < <(find "$setup_dir/themes" -type f | LC_ALL=C sort)

    register_file session_target external systemd/user/sway-noir-session.target \
        "$config_root/systemd/user/sway-noir-session.target" 644 error install
    register_file portal external xdg-desktop-portal/sway-portals.conf \
        "$config_root/xdg-desktop-portal/sway-portals.conf" 644 preserve install

    register_file launcher system session/start-sway-noir /usr/local/bin/start-sway-noir 755 error preserve
    register_login_file login_local /usr/local/share/wayland-sessions/sway-noir.desktop
    register_login_file login_vendor /usr/share/wayland-sessions/sway-noir.desktop
    register_login_file login_etc /etc/wayland-sessions/sway-noir.desktop
}

integration_manifest_key() {
    local target="${files[$1.target]}" scope="${files[$1.scope]}"

    # Preserve the existing checksum format independently of registry IDs.
    [[ "$scope" != external ]] || target="${target#"$config_root/"}"
    printf '%s:%s\n' "$scope" "$target"
}
