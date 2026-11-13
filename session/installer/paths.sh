#!/usr/bin/bash
# Installer paths and symlink safety; shared state is initialized by install.sh.
# shellcheck disable=SC2034,SC2154

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
    profile_manifest="$profile_root/.installed-files.sha256"
    backup_root="$config_root/sway-setup-backups"
    readonly config_root profile_root profile_manifest backup_root
}

initialize_paths() {
    [[ -f "$setup_dir/themes/rain/theme.conf" && -f "$setup_dir/themes/sway.conf" ]] ||
        die 'Missing bundled theme sources; use a complete Sway Noir checkout.'
    initialize_file_registry

    # Derive parent directories from registered targets, children before parents.
    local id directory
    profile_directories=()
    for id in "${profile_files[@]}"; do
        directory="${files[$id.target]%/*}"
        while [[ "$directory" == "$profile_root" || "$directory" == "$profile_root/"* ]]; do
            profile_directories+=("$directory")
            directory="${directory%/*}"
        done
    done
    mapfile -t profile_directories < <(printf '%s\n' "${profile_directories[@]}" | LC_ALL=C sort -ru)

    external_directories=()
    for id in "${external_files[@]}"; do
        external_directories+=("${files[$id.target]%/*}")
    done
    mapfile -t external_directories < <(printf '%s\n' "${external_directories[@]}" | LC_ALL=C sort -ru)
}

profile_path_has_symlink() {
    local relative_path="$1"
    local path="$profile_root" component
    local -a components

    [[ ! -L "$path" ]] || return 0
    IFS=/ read -r -a components <<< "$relative_path"
    for component in "${components[@]}"; do
        path+="/$component"
        [[ ! -L "$path" ]] || return 0
    done
    return 1
}

validate_directory_path() {
    local directory="$1"
    local atomic_local_link="${2:-}" atomic_local_target

    # Walk all ancestors, including missing or dangling directory paths.
    while [[ -n "$directory" ]]; do
        if [[ -L "$directory" ]]; then
            # Only Fedora Atomic's exact system redirects are permitted.
            atomic_local_target="${atomic_local_link%/usr/local}/var/usrlocal"
            if [[ "$directory" == "/home" &&
                  "$(readlink -f -- "$directory")" == "/var/home" ]]; then
                validate_directory_path "/var/home"
            elif [[ -n "$atomic_local_link" && "$directory" == "$atomic_local_link" &&
                  "$(readlink -f -- "$directory")" == "$atomic_local_target" ]]; then
                validate_directory_path "$atomic_local_target"
            else
                die "Refusing symbolic link in target directory path: $directory"
            fi
        fi
        if [[ -e "$directory" && ! -d "$directory" ]]; then
            die "Expected a directory but found another path type: $directory"
        fi
        if [[ "$directory" == / ]]; then
            break
        fi
        directory="${directory%/*}"
    done
}

validate_target_directories() {
    local directory id target_path

    for directory in "${profile_directories[@]}"; do
        validate_directory_path "$directory"
    done
    for id in "${external_files[@]}"; do
        target_path="${files[$id.target]}"
        validate_directory_path "${target_path%/*}"
    done
    if [[ "$uninstall_mode" != true ]]; then
        validate_directory_path "$backup_root"
    fi
    if [[ "$install_login_session" == true || "$uninstall_mode" == true ]]; then
        for id in "${system_files[@]}"; do
            target_path="${files[$id.target]}"
            validate_directory_path "${target_path%/*}" "${files[launcher.target]%/bin/start-sway-noir}"
        done
    fi
}

validate_profile_targets() {
    local relative_path target_path

    for relative_path in "${profile_files[@]}"; do
        target_path="${files[$relative_path.target]}"
        if profile_path_has_symlink "$relative_path"; then
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

    if [[ -L "$profile_manifest" ]] ||
       { [[ -e "$profile_manifest" ]] &&
         { [[ ! -f "$profile_manifest" ]] || ! has_managed_marker "$profile_manifest"; }; }; then
        die "Refusing to replace an unmanaged profile checksum manifest: $profile_manifest"
    fi
}
