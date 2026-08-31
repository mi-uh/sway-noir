#!/usr/bin/bash
set -euo pipefail

setup_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly setup_dir
readonly managed_marker="# Managed by Sway Noir."

config_root=""
profile_root=""
backup_root=""

backup_dir=""
backup_created=false
assume_yes=false
install_login_session=false
set_dark_mode=false
interactive_install=true
uninstall_mode=false
profile_only=false
install_started=false
install_complete=false

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

run() {
    local description="$1"
    shift

    if ! "$@"; then
        die "$description"
    fi
}

usage() {
    cat <<'EOF'
Usage: ./install.sh [-y|--yes] [--login-session] [--set-dark-mode]
       ./install.sh --profile-only
       ./install.sh --uninstall [-y|--yes]

  -y, --yes         Answer yes to all interactive installation questions.
  --login-session   Install the system-wide login-screen entry (uses sudo).
  --set-dark-mode   Set the user-wide GNOME/GTK dark-mode preferences.
  --profile-only    Install only the user profile without optional changes.
  --uninstall       Remove Sway Noir while retaining backups and 99-local.conf.
  -h, --help        Show this help.
EOF
}

initialize_environment() {
    if (( EUID == 0 )); then
        die 'Do not run this installer as root or with sudo. It requests sudo only for the optional login-screen files.'
    fi
    if [[ -z "${HOME:-}" || "$HOME" != /* ]]; then
        die 'HOME must be set to an absolute path.'
    fi

    config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
    if [[ "$config_root" != /* ]]; then
        die 'XDG_CONFIG_HOME must be an absolute path when it is set.'
    fi

    profile_root="$config_root/sway-noir"
    backup_root="$config_root/sway-setup-backups"
    readonly config_root profile_root backup_root
}

require_command() {
    local command_name="$1"

    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command not found: $command_name"
}

report_incomplete_install() {
    local status=$?

    if (( status != 0 )) && [[ "$install_started" == true ]] &&
       [[ "$install_complete" != true ]]; then
        warn 'Installation stopped after file changes had begun.'
        if [[ -n "$backup_dir" ]]; then
            warn "Files replaced before the error were backed up below: $backup_dir"
        fi
    fi
    return "$status"
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
        --profile-only)
            profile_only=true
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
   [[ "$install_login_session" == true || "$set_dark_mode" == true ||
      "$profile_only" == true ]]; then
    printf '%s\n' '--uninstall cannot be combined with installation options.' >&2
    exit 2
fi
if [[ "$profile_only" == true ]] &&
   [[ "$assume_yes" == true || "$install_login_session" == true ||
      "$set_dark_mode" == true ]]; then
    printf '%s\n' '--profile-only cannot be combined with other installation options.' >&2
    exit 2
fi

initialize_environment

confirm() {
    local prompt="$1"
    local default_answer="$2"
    local answer

    while true; do
        printf '%s' "$prompt"
        if [[ ! -t 0 ]] || ! IFS= read -r answer; then
            printf '\nError: unable to read from the terminal; rerun with --yes for non-interactive use.\n' >&2
            exit 1
        fi

        if [[ -z "$answer" ]]; then
            if [[ "$default_answer" == yes ]]; then
                return 0
            fi
            return 1
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

external_actions=(
    "install"
    "install"
)

external_conflict_policies=(
    "error"
    "error"
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
    local candidate

    if [[ -n "$backup_dir" ]]; then
        return
    fi

    run "Could not create backup root: $backup_root" \
        install -d -m 700 "$backup_root"
    if ! candidate="$(mktemp -d "$backup_root/$(date +%Y%m%d-%H%M%S).XXXXXX")"; then
        die "Could not create a unique backup directory below $backup_root"
    fi
    backup_dir="$candidate"
}

backup_file() {
    local source_path="$1"
    local backup_relative_path="$2"
    local backup_path backup_mode

    ensure_backup_dir
    backup_path="$backup_dir/$backup_relative_path"
    if ! backup_mode="$(stat -c '%a' "$source_path")"; then
        die "Could not read file mode for backup: $source_path"
    fi
    run "Could not back up $source_path to $backup_path" \
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
    local left_hash right_hash

    if ! left_hash="$(sha256sum < "$1")"; then
        die "Could not calculate the checksum for $1"
    fi
    if ! right_hash="$(sha256sum < "$2")"; then
        die "Could not calculate the checksum for $2"
    fi
    [[ "$left_hash" == "$right_hash" ]]
}

has_managed_marker() {
    local path="$1"

    head -n 5 "$path" | grep -Fqx "$managed_marker"
}

is_managed_file() {
    local source_path="$1"
    local target_path="$2"
    local source_without_marker target_hash

    if has_managed_marker "$target_path"; then
        return 0
    fi

    # Accept an exact copy from an older Sway Noir release that predates the
    # ownership marker, while still rejecting unrelated files.
    if ! source_without_marker="$(grep -Fvx "$managed_marker" "$source_path" | sha256sum)"; then
        die "Could not calculate the legacy checksum for $source_path"
    fi
    if ! target_hash="$(sha256sum < "$target_path")"; then
        die "Could not calculate the checksum for $target_path"
    fi
    [[ "$source_without_marker" == "$target_hash" ]]
}

is_managed_external_file() {
    local index="$1"
    local source_path="$2"
    local target_path="$3"

    if is_managed_file "$source_path" "$target_path"; then
        return 0
    fi

    # Early development versions installed this project-specific target before
    # adding the ownership marker and Documentation field. Its unit name and
    # Sway Noir description make it safe to migrate; unrelated units still fail.
    if (( index == 0 )) &&
       grep -Fqx '[Unit]' "$target_path" &&
       grep -Fq 'Sway Noir' "$target_path" &&
       grep -Fqx 'BindsTo=graphical-session.target' "$target_path"; then
        return 0
    fi

    return 1
}

check_installer_commands() {
    local command_name
    local -a commands=(
        chmod date grep head install mktemp rm rmdir sha256sum stat systemctl
    )

    for command_name in "${commands[@]}"; do
        require_command "$command_name"
    done
}

check_runtime_dependencies() {
    local command_name
    local -a missing_commands=()
    local -a runtime_commands=(
        brightnessctl
        dbus-update-activation-environment
        foot
        fuzzel
        gammastep
        grim
        mako
        pactl
        pavucontrol
        playerctl
        sway
        swaybg
        swaylock
        waybar
    )

    for command_name in "${runtime_commands[@]}"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing_commands+=("$command_name")
        fi
    done

    if (( ${#missing_commands[@]} > 0 )); then
        printf 'Error: required runtime commands are missing:\n' >&2
        printf '  %s\n' "${missing_commands[@]}" >&2
        printf '\nInstall the Fedora dependencies first:\n' >&2
        printf '%s\n' \
            '  sudo dnf install sway swaybg swaylock waybar fuzzel mako foot gammastep \' \
            '      ibm-plex-sans-fonts playerctl brightnessctl grim pulseaudio-utils \' \
            '      pavucontrol \' \
            '      dconf gsettings-desktop-schemas pipewire wireplumber \' \
            '      xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr' >&2
        exit 1
    fi
}

validate_profile_targets() {
    local relative_path target_path

    for relative_path in "${profile_files[@]}"; do
        target_path="$profile_root/$relative_path"
        if [[ -L "$target_path" ]]; then
            die "Refusing to replace symbolic link in the managed profile: $target_path"
        fi
        if [[ -e "$target_path" && ! -f "$target_path" ]]; then
            die "Expected a regular file but found another path type: $target_path"
        fi
    done

    target_path="$profile_root/sway/config.d/99-local.conf"
    if [[ -e "$target_path" && ! -f "$target_path" && ! -L "$target_path" ]]; then
        die "Expected 99-local.conf to be a file or symbolic link: $target_path"
    fi
}

handle_external_conflict() {
    local index="$1"
    local description="$2"
    local target_path="$3"

    if [[ "${external_conflict_policies[$index]}" == preserve ]]; then
        external_actions[$index]="preserve"
        warn "Preserving $description: $target_path"
        return
    fi
    die "Refusing $description: $target_path"
}

verify_installation() {
    local index relative_path source_path target_path

    for relative_path in "${profile_files[@]}"; do
        source_path="$setup_dir/$relative_path"
        target_path="$profile_root/$relative_path"
        if [[ ! -f "$target_path" ]] || ! files_equal "$source_path" "$target_path"; then
            die "Verification failed for installed profile file: $target_path"
        fi
    done

    target_path="$profile_root/sway/config.d/99-local.conf"
    if [[ ! -f "$target_path" && ! -L "$target_path" ]]; then
        die "Verification failed for preserved local configuration: $target_path"
    fi

    for index in "${!external_sources[@]}"; do
        if [[ "${external_actions[$index]}" != install ]]; then
            continue
        fi
        source_path="$setup_dir/${external_sources[$index]}"
        target_path="$config_root/${external_targets[$index]}"
        if [[ ! -f "$target_path" ]] || ! files_equal "$source_path" "$target_path"; then
            die "Verification failed for installed integration file: $target_path"
        fi
    done

    if [[ "$install_login_session" == true ]]; then
        for index in "${!system_sources[@]}"; do
            source_path="$setup_dir/${system_sources[$index]}"
            target_path="${system_targets[$index]}"
            if [[ ! -f "$target_path" ]] || ! files_equal "$source_path" "$target_path"; then
                die "Verification failed for installed system file: $target_path"
            fi
        done
    fi

    if [[ "$set_dark_mode" == true ]]; then
        if [[ "$(gsettings get org.gnome.desktop.interface color-scheme)" != "'prefer-dark'" ]]; then
            die 'Verification failed for the application color scheme.'
        fi
        if [[ "$(gsettings get org.gnome.desktop.interface gtk-theme)" != "'Adwaita-dark'" ]]; then
            die 'Verification failed for the GTK theme.'
        fi
    fi
}

print_install_plan() {
    local index relative_path target_path

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
    for index in "${!external_targets[@]}"; do
        target_path="$config_root/${external_targets[$index]}"
        if [[ "${external_actions[$index]}" == install ]]; then
            printf '  %s\n' "$target_path"
        else
            printf '  %s (preserved: existing file is not managed by Sway Noir)\n' \
                "$target_path"
        fi
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

    if command -v systemctl >/dev/null 2>&1 &&
       ! systemctl --user stop sway-noir-session.target; then
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

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl --user daemon-reload; then
            printf 'Warning: failed to reload the user systemd manager.\n' >&2
        fi
    else
        printf 'Warning: systemctl not found; skipped the user systemd reload.\n' >&2
    fi
    printf 'Sway Noir uninstalled. Backups, 99-local.conf and dark-mode settings were preserved.\n'
}

check_installer_commands

if [[ "$uninstall_mode" == true ]]; then
    print_uninstall_plan
    if [[ "$assume_yes" != true ]] &&
       ! confirm 'Proceed with uninstalling Sway Noir? [y/N] ' no; then
        printf 'Uninstallation cancelled.\n'
        exit 0
    fi
    uninstall_sway_noir
    exit 0
fi

if [[ "$assume_yes" == true ]]; then
    install_login_session=true
    set_dark_mode=true
elif [[ "$interactive_install" == true ]]; then
    if confirm 'Add Sway Noir to the login screen? This requires sudo. [y/N] ' no; then
        install_login_session=true
    fi
    if confirm 'Enable dark mode for applications? This changes user-wide settings. [y/N] ' no; then
        set_dark_mode=true
    fi
fi

check_runtime_dependencies

if [[ "$install_login_session" == true ]]; then
    require_command sudo
fi

dark_color_before=""
dark_theme_before=""
if [[ "$set_dark_mode" == true ]]; then
    require_command gsettings
    if ! dark_color_before="$(gsettings get org.gnome.desktop.interface color-scheme)"; then
        die 'Could not read org.gnome.desktop.interface color-scheme.'
    fi
    if ! dark_theme_before="$(gsettings get org.gnome.desktop.interface gtk-theme)"; then
        die 'Could not read org.gnome.desktop.interface gtk-theme.'
    fi
fi

# Validate all sources and external ownership before changing any files.
if (( ${#external_sources[@]} != ${#external_targets[@]} )); then
    die 'Internal error: external source and target lists have different lengths.'
fi
if (( ${#external_sources[@]} != ${#external_conflict_policies[@]} )); then
    die 'Internal error: external source and conflict-policy lists have different lengths.'
fi
if (( ${#system_sources[@]} != ${#system_targets[@]} )); then
    die 'Internal error: system source and target lists have different lengths.'
fi

for relative_path in "${profile_files[@]}"; do
    source_path="$setup_dir/$relative_path"
    if [[ ! -f "$source_path" ]]; then
        die "Missing source file: $source_path"
    fi
done
if [[ ! -f "$setup_dir/sway/config.d/99-local.conf.example" ]]; then
    die "Missing source file: $setup_dir/sway/config.d/99-local.conf.example"
fi

validate_profile_targets

for index in "${!external_sources[@]}"; do
    source_path="$setup_dir/${external_sources[$index]}"
    target_path="$config_root/${external_targets[$index]}"

    if [[ ! -f "$source_path" ]]; then
        die "Missing source file: $source_path"
    fi
    if [[ -L "$target_path" ]]; then
        handle_external_conflict "$index" \
            'symbolic link not managed by Sway Noir' "$target_path"
    elif [[ -e "$target_path" && ! -f "$target_path" ]]; then
        handle_external_conflict "$index" \
            'non-file path not managed by Sway Noir' "$target_path"
    elif [[ -f "$target_path" ]] &&
         ! files_equal "$source_path" "$target_path" &&
         ! is_managed_external_file "$index" "$source_path" "$target_path"; then
        handle_external_conflict "$index" \
            'existing file not managed by Sway Noir' "$target_path"
    fi
done

if [[ "$install_login_session" == true ]]; then
    for index in "${!system_sources[@]}"; do
        source_path="$setup_dir/${system_sources[$index]}"
        target_path="${system_targets[$index]}"

        if [[ ! -f "$source_path" ]]; then
            die "Missing source file: $source_path"
        fi
        if [[ -L "$target_path" ]]; then
            die "Refusing to replace symbolic link: $target_path"
        fi
        if [[ -e "$target_path" && ! -f "$target_path" ]]; then
            die "Refusing to replace non-file path: $target_path"
        fi
        if [[ -f "$target_path" ]] && ! files_equal "$source_path" "$target_path" &&
           ! is_managed_file "$source_path" "$target_path"; then
            die "Refusing to overwrite unmanaged file: $target_path"
        fi
    done
fi

print_install_plan

if [[ "$interactive_install" == true ]] &&
   ! confirm 'Proceed with installing Sway Noir? [y/N] ' no; then
    printf 'Installation cancelled.\n'
    exit 0
fi

if [[ "$install_login_session" == true ]]; then
    run 'sudo authentication failed; no files were installed.' sudo -v
fi

trap report_incomplete_install EXIT
install_started=true

for relative_path in "${profile_files[@]}"; do
    source_path="$setup_dir/$relative_path"
    target_path="$profile_root/$relative_path"

    if [[ -f "$target_path" ]] && files_equal "$source_path" "$target_path"; then
        continue
    fi
    if [[ -e "$target_path" ]]; then
        backup_file "$target_path" "sway-noir/$relative_path"
    fi

    mode="$(profile_mode "$relative_path")"
    run "Could not install $target_path" \
        install -D -m "$mode" "$source_path" "$target_path"
done

local_target="$profile_root/sway/config.d/99-local.conf"
if [[ ! -e "$local_target" && ! -L "$local_target" ]]; then
    run "Could not create $local_target" \
        install -D -m 644 "$setup_dir/sway/config.d/99-local.conf.example" "$local_target"
fi

for index in "${!external_sources[@]}"; do
    source_path="$setup_dir/${external_sources[$index]}"
    relative_target="${external_targets[$index]}"
    target_path="$config_root/$relative_target"

    if [[ "${external_actions[$index]}" != install ]]; then
        continue
    fi
    if [[ -f "$target_path" ]] && files_equal "$source_path" "$target_path"; then
        continue
    fi
    if [[ -f "$target_path" ]]; then
        backup_file "$target_path" "$relative_target"
    fi
    run "Could not install $target_path" \
        install -D -m 644 "$source_path" "$target_path"
done

if ! systemctl --user daemon-reload; then
    warn 'The user systemd manager is not currently reachable; it will load the unit on the next login.'
fi

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
                run "Could not install system file $target_path" \
                    sudo install -D -m 755 "$source_path" "$target_path"
                ;;
            *)
                run "Could not install system file $target_path" \
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
        run "Could not make rollback script executable: $rollback_path" \
            chmod 700 "$rollback_path"
        backup_created=true

        if [[ "$dark_color_before" != "'prefer-dark'" ]]; then
            run 'Could not set the application color scheme.' \
                gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
        fi
        if [[ "$dark_theme_before" != "'Adwaita-dark'" ]]; then
            run 'Could not set the GTK theme.' \
                gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
        fi
        printf 'Dark-mode preferences set. Rollback: %s\n' "$rollback_path"
    fi
fi

verify_installation
install_complete=true
trap - EXIT

if [[ "$backup_created" == true ]]; then
    printf 'Backup: %s\n' "$backup_dir"
fi

printf 'Installed Sway Noir below %s\n' "$profile_root"
if [[ "$install_login_session" == true ]]; then
    printf 'Installed the Sway Noir login-screen session.\n'
fi
printf 'Start from a TTY with: %s/start-sway-noir\n' "$profile_root"
