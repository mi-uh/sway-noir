#!/usr/bin/bash
# Options, prompts and operation plans; sourced by install.sh.
# shellcheck disable=SC2034,SC2154

usage() {
    cat <<'EOF'
Usage: ./install.sh [-y|--yes] [--login-session] [--set-dark-mode]
       ./install.sh --profile-only
       ./install.sh --check-deps [--set-dark-mode]
       ./install.sh --list-deps
       ./install.sh --uninstall [-y|--yes]

  -y, --yes         Answer yes to all interactive installation questions.
  --login-session   Install the system-wide login-screen entry (uses sudo).
  --set-dark-mode   Set the user-wide GNOME/GTK dark-mode preferences.
  --profile-only    Install only the user profile without optional changes.
  --uninstall       Remove Sway Noir while retaining backups and 99-local.conf.
  --check-deps      Check dependencies and print hints; do not change anything.
  --list-deps       List dependency checks and distribution package hints.
  -h, --help        Show this help.
EOF
}

parse_arguments() {
    local argument
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
            --check-deps)
                check_deps_only=true
                interactive_install=false
                ;;
            --list-deps)
                list_deps_only=true
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

    if [[ "$list_deps_only" == true && ( "$check_deps_only" == true || "$set_dark_mode" == true ) ]]; then
        printf '%s\n' '--list-deps cannot be combined with other dependency options.' >&2
        exit 2
    fi
    if [[ "$check_deps_only" == true || "$list_deps_only" == true ]] &&
       [[ "$assume_yes" == true || "$install_login_session" == true ||
          "$uninstall_mode" == true || "$profile_only" == true ]]; then
        printf '%s\n' 'Dependency inspection cannot be combined with installation or uninstall options (except --set-dark-mode).' >&2
        exit 2
    fi
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
}

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
            y|yes|j|ja) return 0 ;;
            n|no|nein) return 1 ;;
            *) printf 'Please answer yes or no.\n' ;;
        esac
    done
}

select_install_options() {
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
}

print_install_plan() {
    local id relative_path target_path

    printf '\nInstallation plan\n'
    printf 'Directories created as needed:\n'
    for target_path in "${profile_directories[@]}"; do
        printf '  %s\n' "$target_path"
    done
    for target_path in "${external_directories[@]}"; do
        printf '  %s\n' "$target_path"
    done
    printf '  %s (only when a backup or dark-mode rollback is needed)\n' "$backup_root"

    printf 'Files installed or updated:\n'
    for relative_path in "${profile_files[@]}"; do
        printf '  %s\n' "${files[$relative_path.target]}"
    done
    if (( ${#obsolete_theme_files[@]} > 0 )); then
        printf 'Obsolete unchanged theme files (backed up and removed after verification):\n'
        for relative_path in "${obsolete_theme_files[@]}"; do
            printf '  %s\n' "$profile_root/$relative_path"
        done
        printf 'Other installed files:\n'
    fi
    printf '  %s (installed file checksums)\n' "$profile_manifest"
    printf '  %s (created only when missing; never overwritten)\n' \
        "$profile_root/sway/config.d/99-local.conf"
    for id in "${external_files[@]}"; do
        target_path="${files[$id.target]}"
        case "${files[$id.action]}" in
            install) printf '  %s\n' "$target_path" ;;
            preserve) printf '  %s (preserved: existing or modified configuration)\n' "$target_path" ;;
            remove) printf '  %s (backed up and removed; use %s)\n' "$target_path" "$portal_configuration" ;;
            skip) printf '  %s (not installed; use %s)\n' "$target_path" "$portal_configuration" ;;
        esac
    done
    if [[ "$install_login_session" == true ]]; then
        printf 'System files changed with sudo:\n'
        for id in "${system_files[@]}"; do
            [[ "${files[$id.action]}" != preserve ]] || continue
            printf '  %s (%s)\n' "${files[$id.target]}" "${files[$id.action]}"
        done
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
    local id relative_path target_path

    printf '\nUninstallation plan\n'
    printf 'Known Sway Noir files to remove only when unchanged (symbolic links are preserved):\n'
    for relative_path in "${profile_files[@]}"; do
        printf '  %s\n' "${files[$relative_path.target]}"
    done
    printf '  %s (only when managed)\n' "$profile_manifest"
    for id in "${external_files[@]}"; do
        printf '  %s (only when verified unchanged)\n' "${files[$id.target]}"
    done
    for id in "${system_files[@]}"; do
        printf '  %s (only when verified unchanged; removal uses sudo)\n' "${files[$id.target]}"
    done
    printf 'Empty Sway Noir directories will be removed.\n'
    printf 'Always preserved:\n'
    printf '  %s\n' "$profile_root/sway/config.d/99-local.conf"
    printf '  %s\n' "$backup_root"
    printf '  User-wide dark-mode settings\n'
    printf '  %s (saved theme and generated appearance)\n' "${XDG_STATE_HOME:-$HOME/.local/state}/sway-noir"
    printf '  Unknown files not managed by Sway Noir\n\n'
}
