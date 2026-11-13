#!/usr/bin/bash
set -euo pipefail

setup_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly setup_dir
readonly managed_marker="# Managed by Sway Noir."

# Shared operation state. Modules define functions without running checks/writes.
config_root=""
profile_root=""
profile_manifest=""
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
check_deps_only=false
list_deps_only=false
portal_configuration=""
obsolete_theme_files=()
obsolete_theme_checksums=()

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

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# shellcheck source=session/dependencies.sh
source "$setup_dir/session/dependencies.sh"
# shellcheck source=session/login-integration.sh
source "$setup_dir/session/login-integration.sh"
# shellcheck source=session/installer/cli.sh
source "$setup_dir/session/installer/cli.sh"
# shellcheck source=session/installer/files.sh
source "$setup_dir/session/installer/files.sh"
# shellcheck source=session/installer/paths.sh
source "$setup_dir/session/installer/paths.sh"
# shellcheck source=session/installer/backups.sh
source "$setup_dir/session/installer/backups.sh"
# shellcheck source=session/installer/profile.sh
source "$setup_dir/session/installer/profile.sh"
# shellcheck source=session/installer/integrations.sh
source "$setup_dir/session/installer/integrations.sh"
# shellcheck source=session/installer/verification.sh
source "$setup_dir/session/installer/verification.sh"
# shellcheck source=session/installer/uninstall.sh
source "$setup_dir/session/installer/uninstall.sh"

main() {
    parse_arguments "$@"
    if [[ "$list_deps_only" == true ]]; then
        list_dependencies
        return
    fi
    initialize_environment
    check_installer_commands
    initialize_paths

    if [[ "$check_deps_only" == true ]]; then
        check_runtime_dependencies
        return
    fi
    if [[ "$uninstall_mode" == true ]]; then
        require_command findmnt
        require_command readlink
        print_uninstall_plan
        if [[ "$assume_yes" != true ]] &&
           ! confirm 'Proceed with uninstalling Sway Noir? [y/N] ' no; then
            printf 'Uninstallation cancelled.\n'
            exit 0
        fi
        uninstall_sway_noir
        exit 0
    fi

    # Preflight: finish checks and display the plan before changing files.
    select_install_options
    check_runtime_dependencies || return 1
    if [[ "$install_login_session" == true ]]; then
        require_command sudo
        configure_login_session
    fi
    read_dark_mode_preferences
    preflight_installation
    print_install_plan
    if [[ "$interactive_install" == true ]] &&
       ! confirm 'Proceed with installing Sway Noir? [y/N] ' no; then
        printf 'Installation cancelled.\n'
        exit 0
    fi
    if [[ "$install_login_session" == true ]]; then
        run 'sudo authentication failed; no files were installed.' sudo -v
    fi

    # Apply: replacements retain backups; failures report the recovery path.
    trap report_incomplete_install EXIT
    install_started=true
    install_profile_files
    install_external_files
    if ! systemctl --user daemon-reload; then
        warn 'The user systemd manager is not currently reachable; it will load the unit on the next login.'
    fi
    install_login_files
    apply_dark_mode

    # Commit ownership only after verification and obsolete-file cleanup finish.
    verify_installation
    remove_obsolete_theme_files
    remove_old_login_files
    write_profile_manifest
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
