#!/usr/bin/bash
set -euo pipefail

readonly setup_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly profile_root="$config_root/sway-noir"
readonly backup_root="$config_root/sway-setup-backups"
readonly managed_marker="# Managed by Sway Noir."

backup_dir=""
backup_created=false
assume_yes=false
install_login_session=false
set_dark_mode=false
interactive_install=true
uninstall_mode=false

usage() {
    cat <<'EOF'
Usage: ./install.sh [-y|--yes] [--login-session] [--set-dark-mode]
       ./install.sh --uninstall [-y|--yes]

  -y, --yes         Answer yes to all interactive installation questions.
  --login-session   Install the system-wide login-screen entry (uses sudo).
  --set-dark-mode   Set the user-wide GNOME/GTK dark-mode preferences.
  --uninstall       Remove Sway Noir while retaining backups and 99-local.conf.
  -h, --help        Show this help.
EOF
}

for argument in "$@"; do
    case "$argument" in
        -y|--yes)
            assume_yes=true
            interactive_install=false
            ;;
        --login-session)
            install_login_session=true
            interactive_install=false
            ;;
        --set-dark-mode)
            set_dark_mode=true
            interactive_install=false
            ;;
        --uninstall)
            uninstall_mode=true
            interactive_install=false
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$argument" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$uninstall_mode" == true ]] &&
   [[ "$install_login_session" == true || "$set_dark_mode" == true ]]; then
    printf '%s\n' '--uninstall cannot be combined with installation options.' >&2
    exit 2
fi

confirm() {
    local prompt="$1"
    local default_answer="$2"
    local answer

    while true; do
        printf '%s' "$prompt"
        if ! IFS= read -r answer; then
            printf '\nNo answer received; installation cancelled.\n' >&2
            exit 2
        fi

        if [[ -z "$answer" ]]; then
            [[ "$default_answer" == yes ]]
            return
        fi

        case "${answer,,}" in
            y|yes|j|ja)
                return 0
                ;;
            n|no|nein)
                return 1
                ;;
            *)
                printf 'Please answer yes or no.\n'
                ;;
        esac
    done
}

profile_files=(
    "start-sway-noir"
    "session/start-session"
    "sway/config"
    "sway/config.d/20-outputs.conf"
    "sway/config.d/40-look.conf"
    "sway/config.d/50-input.conf"
    "sway/config.d/60-keybindings.conf"
    "sway/config.d/90-bar.conf"
    "sway/config.d/99-startup.conf"
    "sway/backgrounds/cozy-cyberpunk-room.png"
    "waybar/config.jsonc"
    "waybar/style.css"
    "fuzzel/fuzzel.ini"
    "mako/config"
    "gammastep/config.ini"
    "swaylock/config"
    "swaylock/cozy-cyberpunk-room-lock.png"
)

external_sources=(
    "systemd/user/sway-noir-session.target"
    "xdg-desktop-portal/sway-portals.conf"
)

external_targets=(
    "systemd/user/sway-noir-session.target"
    "xdg-desktop-portal/sway-portals.conf"
)

system_sources=(
    "session/start-sway-noir"
    "session/sway-noir.desktop"
)

system_targets=(
    "/usr/local/bin/start-sway-noir"
    "/usr/share/wayland-sessions/sway-noir.desktop"
)

profile_directories=(
    "$profile_root/session"
    "$profile_root/sway/backgrounds"
    "$profile_root/sway/config.d"
    "$profile_root/waybar"
    "$profile_root/fuzzel"
    "$profile_root/mako"
    "$profile_root/gammastep"
    "$profile_root/swaylock"
    "$profile_root/sway"
    "$profile_root"
)

ensure_backup_dir() {
    local candidate counter

    if [[ -n "$backup_dir" ]]; then
        return
    fi

    install -d -m 700 "$backup_root"
    candidate="$backup_root/$(date +%Y%m%d-%H%M%S)"
    counter=0
    while [[ -e "$candidate" ]]; do
        counter=$((counter + 1))
        candidate="$backup_root/$(date +%Y%m%d-%H%M%S)-$counter"
    done
    install -d -m 700 "$candidate"
    backup_dir="$candidate"
}

backup_file() {
    local source_path="$1"
    local backup_relative_path="$2"
    local backup_path backup_mode

    ensure_backup_dir
    backup_path="$backup_dir/$backup_relative_path"
    backup_mode="$(stat -c '%a' "$source_path")"
    install -D -p -m "$backup_mode" "$source_path" "$backup_path"
    backup_created=true
}

profile_mode() {
    case "$1" in
        start-sway-noir|session/start-session)
            printf '755\n'
            ;;
        *)
            printf '644\n'
            ;;
    esac
}

files_equal() {
    [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]
}

has_managed_marker() {
    local path="$1"

    head -n 5 "$path" | grep -Fqx "$managed_marker"
}

is_managed_file() {
    local source_path="$1"
    local target_path="$2"

    if has_managed_marker "$target_path"; then
        return 0
    fi

    # Accept an exact copy from an older Sway Noir release that predates the
    # ownership marker, while still rejecting unrelated files.
    [[ "$(grep -Fvx "$managed_marker" "$source_path" | sha256sum)" == \
       "$(sha256sum < "$target_path")" ]]
}

print_install_plan() {
    local relative_path target_path

    printf '\nInstallation plan\n'
    printf 'Directories created as needed:\n'
    for target_path in \
        "$profile_root" \
        "$profile_root/session" \
        "$profile_root/sway/config.d" \
        "$profile_root/sway/backgrounds" \
        "$profile_root/waybar" \
        "$profile_root/fuzzel" \
        "$profile_root/mako" \
        "$profile_root/gammastep" \
        "$profile_root/swaylock" \
        "$config_root/systemd/user" \
        "$config_root/xdg-desktop-portal"; do
        printf '  %s\n' "$target_path"
    done
    printf '  %s (only when a backup or dark-mode rollback is needed)\n' "$backup_root"

    printf 'Files installed or updated:\n'
    for relative_path in "${profile_files[@]}"; do
        printf '  %s\n' "$profile_root/$relative_path"
    done
    printf '  %s (created only when missing; never overwritten)\n' \
        "$profile_root/sway/config.d/99-local.conf"
    for target_path in "${external_targets[@]}"; do
        printf '  %s\n' "$config_root/$target_path"
    done
    if [[ "$install_login_session" == true ]]; then
        printf 'System files installed with sudo:\n'
        printf '  %s\n' "${system_targets[@]}"
    else
        printf 'Login-screen system files: not selected\n'
    fi
    if [[ "$set_dark_mode" == true ]]; then
        printf 'User-wide dark-mode settings: selected\n'
    else
        printf 'User-wide dark-mode settings: unchanged\n'
    fi
    printf '\n'
}

print_uninstall_plan() {
    local relative_path target_path

    printf '\nUninstallation plan\n'
    printf 'Known Sway Noir files to remove when present:\n'
    for relative_path in "${profile_files[@]}"; do
        printf '  %s\n' "$profile_root/$relative_path"
    done
    for target_path in "${external_targets[@]}"; do
        printf '  %s (only when marked as managed)\n' "$config_root/$target_path"
    done
    for target_path in "${system_targets[@]}"; do
        printf '  %s (only when managed; removal uses sudo)\n' "$target_path"
    done
    printf 'Empty Sway Noir directories will be removed.\n'
    printf 'Always preserved:\n'
    printf '  %s\n' "$profile_root/sway/config.d/99-local.conf"
    printf '  %s\n' "$backup_root"
    printf '  User-wide dark-mode settings\n'
    printf '  Unknown files not managed by Sway Noir\n\n'
}

uninstall_sway_noir() {
    local index relative_path target_path
    local -a managed_system_indexes=()

    for index in "${!system_sources[@]}"; do
        target_path="${system_targets[$index]}"
        if [[ -L "$target_path" ]]; then
            printf 'Preserving symbolic link not managed by Sway Noir: %s\n' "$target_path" >&2
        elif [[ -f "$target_path" ]] &&
             is_managed_file "$setup_dir/${system_sources[$index]}" "$target_path"; then
            managed_system_indexes+=("$index")
        elif [[ -e "$target_path" ]]; then
            printf 'Preserving system path not managed by Sway Noir: %s\n' "$target_path" >&2
        fi
    done

    if (( ${#managed_system_indexes[@]} > 0 )); then
        if ! command -v sudo >/dev/null 2>&1; then
            printf 'Required command not found: sudo\n' >&2
            exit 1
        fi
        sudo -v
    fi

    if ! systemctl --user stop sway-noir-session.target; then
        printf 'Warning: failed to stop sway-noir-session.target\n' >&2
    fi

    for relative_path in "${profile_files[@]}"; do
        target_path="$profile_root/$relative_path"
        if [[ -L "$target_path" || -f "$target_path" ]]; then
            rm -f -- "$target_path"
            printf 'Removed: %s\n' "$target_path"
        elif [[ -e "$target_path" ]]; then
            printf 'Preserving unexpected non-file path: %s\n' "$target_path" >&2
        fi
    done

    for target_path in "${external_targets[@]}"; do
        target_path="$config_root/$target_path"
        if [[ -L "$target_path" ]]; then
            printf 'Preserving symbolic link not managed by Sway Noir: %s\n' "$target_path" >&2
        elif [[ -f "$target_path" ]] && has_managed_marker "$target_path"; then
            rm -f -- "$target_path"
            printf 'Removed: %s\n' "$target_path"
        elif [[ -e "$target_path" ]]; then
            printf 'Preserving file not managed by Sway Noir: %s\n' "$target_path" >&2
        fi
    done

    for index in "${managed_system_indexes[@]}"; do
        target_path="${system_targets[$index]}"
        sudo rm -f -- "$target_path"
        printf 'Removed: %s\n' "$target_path"
    done

    for target_path in "${profile_directories[@]}" \
        "$config_root/systemd/user" \
        "$config_root/xdg-desktop-portal"; do
        if rmdir -- "$target_path" 2>/dev/null; then
            printf 'Removed empty directory: %s\n' "$target_path"
        fi
    done

    systemctl --user daemon-reload
    printf 'Sway Noir uninstalled. Backups, 99-local.conf and dark-mode settings were preserved.\n'
}

if [[ "$uninstall_mode" == true ]]; then
    print_uninstall_plan
    if [[ "$assume_yes" != true ]] &&
       ! confirm 'Proceed with uninstalling Sway Noir? [y/N] ' no; then
        printf 'Uninstallation cancelled.\n'
        exit 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        printf 'Required command not found: systemctl\n' >&2
        exit 1
    fi
    uninstall_sway_noir
    exit 0
fi

if [[ "$assume_yes" == true ]]; then
    install_login_session=true
    set_dark_mode=true
elif [[ "$interactive_install" == true ]]; then
    if ! confirm "Install Sway Noir to $profile_root? [Y/n] " yes; then
        printf 'Installation cancelled.\n'
        exit 0
    fi
    if confirm 'Add Sway Noir to the login screen? This requires sudo. [y/N] ' no; then
        install_login_session=true
    fi
    if confirm 'Enable dark mode for applications? This changes user-wide settings. [y/N] ' no; then
        set_dark_mode=true
    fi
fi

print_install_plan

if ! command -v systemctl >/dev/null 2>&1; then
    printf 'Required command not found: systemctl\n' >&2
    exit 1
fi

if [[ "$install_login_session" == true ]] &&
   ! command -v sudo >/dev/null 2>&1; then
    printf 'Required command not found: sudo\n' >&2
    exit 1
fi

dark_color_before=""
dark_theme_before=""
if [[ "$set_dark_mode" == true ]]; then
    if ! command -v gsettings >/dev/null 2>&1; then
        printf 'Required command not found: gsettings\n' >&2
        exit 1
    fi
    dark_color_before="$(gsettings get org.gnome.desktop.interface color-scheme)"
    dark_theme_before="$(gsettings get org.gnome.desktop.interface gtk-theme)"
fi

# Validate all sources and external ownership before changing any files.
for relative_path in "${profile_files[@]}"; do
    source_path="$setup_dir/$relative_path"
    if [[ ! -f "$source_path" ]]; then
        printf 'Missing source file: %s\n' "$source_path" >&2
        exit 1
    fi
done

for index in "${!external_sources[@]}"; do
    source_path="$setup_dir/${external_sources[$index]}"
    target_path="$config_root/${external_targets[$index]}"

    if [[ ! -f "$source_path" ]]; then
        printf 'Missing source file: %s\n' "$source_path" >&2
        exit 1
    fi
    if [[ -L "$target_path" ]]; then
        printf 'Refusing to replace symbolic link: %s\n' "$target_path" >&2
        exit 1
    fi
    if [[ -e "$target_path" && ! -f "$target_path" ]]; then
        printf 'Refusing to replace non-file path: %s\n' "$target_path" >&2
        exit 1
    fi
    if [[ -f "$target_path" ]] && ! files_equal "$source_path" "$target_path"; then
        IFS= read -r first_line < "$target_path" || true
        if [[ "$first_line" != "$managed_marker" ]]; then
            printf 'Refusing to overwrite unmanaged file: %s\n' "$target_path" >&2
            exit 1
        fi
    fi
done

if [[ "$install_login_session" == true ]]; then
    for index in "${!system_sources[@]}"; do
        source_path="$setup_dir/${system_sources[$index]}"
        target_path="${system_targets[$index]}"

        if [[ ! -f "$source_path" ]]; then
            printf 'Missing source file: %s\n' "$source_path" >&2
            exit 1
        fi
        if [[ -L "$target_path" ]]; then
            printf 'Refusing to replace symbolic link: %s\n' "$target_path" >&2
            exit 1
        fi
        if [[ -e "$target_path" && ! -f "$target_path" ]]; then
            printf 'Refusing to replace non-file path: %s\n' "$target_path" >&2
            exit 1
        fi
        if [[ -f "$target_path" ]] && ! files_equal "$source_path" "$target_path" &&
           ! is_managed_file "$source_path" "$target_path"; then
            printf 'Refusing to overwrite unmanaged file: %s\n' "$target_path" >&2
            exit 1
        fi
    done

    # Authenticate before writing user files so a cancelled sudo prompt cannot
    # leave a partially completed installation.
    sudo -v
fi

for relative_path in "${profile_files[@]}"; do
    source_path="$setup_dir/$relative_path"
    target_path="$profile_root/$relative_path"

    if [[ -e "$target_path" ]]; then
        backup_file "$target_path" "sway-noir/$relative_path"
    fi

    mode="$(profile_mode "$relative_path")"
    install -D -m "$mode" "$source_path" "$target_path"
done

local_target="$profile_root/sway/config.d/99-local.conf"
if [[ ! -e "$local_target" ]]; then
    install -D -m 644 "$setup_dir/sway/config.d/99-local.conf.example" "$local_target"
fi

for index in "${!external_sources[@]}"; do
    source_path="$setup_dir/${external_sources[$index]}"
    relative_target="${external_targets[$index]}"
    target_path="$config_root/$relative_target"

    if [[ -f "$target_path" ]] && files_equal "$source_path" "$target_path"; then
        continue
    fi
    if [[ -f "$target_path" ]]; then
        backup_file "$target_path" "$relative_target"
    fi
    install -D -m 644 "$source_path" "$target_path"
done

systemctl --user daemon-reload

if [[ "$install_login_session" == true ]]; then
    for index in "${!system_sources[@]}"; do
        source_path="$setup_dir/${system_sources[$index]}"
        target_path="${system_targets[$index]}"

        if [[ -f "$target_path" ]] && files_equal "$source_path" "$target_path"; then
            continue
        fi
        if [[ -f "$target_path" ]]; then
            backup_file "$target_path" "system$target_path"
        fi
        case "$target_path" in
            /usr/local/bin/*)
                sudo install -D -m 755 "$source_path" "$target_path"
                ;;
            *)
                sudo install -D -m 644 "$source_path" "$target_path"
                ;;
        esac
    done
fi

if [[ "$set_dark_mode" == true ]]; then
    if [[ "$dark_color_before" == "'prefer-dark'" &&
          "$dark_theme_before" == "'Adwaita-dark'" ]]; then
        printf 'Dark-mode preferences are already set; no GSettings values changed.\n'
    else
        printf 'Previous color-scheme: %s\n' "$dark_color_before"
        printf 'Previous gtk-theme: %s\n' "$dark_theme_before"

        ensure_backup_dir
        rollback_path="$backup_dir/restore-dark-mode.sh"
        {
            printf '#!/usr/bin/bash\n'
            printf 'set -euo pipefail\n\n'
            printf 'gsettings set org.gnome.desktop.interface color-scheme %q\n' "$dark_color_before"
            printf 'gsettings set org.gnome.desktop.interface gtk-theme %q\n' "$dark_theme_before"
        } > "$rollback_path"
        chmod 700 "$rollback_path"
        backup_created=true

        if [[ "$dark_color_before" != "'prefer-dark'" ]]; then
            gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
        fi
        if [[ "$dark_theme_before" != "'Adwaita-dark'" ]]; then
            gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
        fi
        printf 'Dark-mode preferences set. Rollback: %s\n' "$rollback_path"
    fi
fi

if [[ "$backup_created" == true ]]; then
    printf 'Backup: %s\n' "$backup_dir"
fi

printf 'Installed Sway Noir below %s\n' "$profile_root"
if [[ "$install_login_session" == true ]]; then
    printf 'Installed the Sway Noir login-screen session.\n'
fi
printf 'Start from a TTY with: %s/start-sway-noir\n' "$profile_root"
