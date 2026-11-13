#!/usr/bin/bash
# Preflight and post-install verification; sourced by install.sh.
# shellcheck disable=SC2154

check_installer_commands() {
    local command_name
    local -a commands=(
        chmod date find grep head install mktemp mv readlink rm rmdir sha256sum sort stat systemctl
    )
    for command_name in "${commands[@]}"; do
        require_command "$command_name"
    done
}

check_systemd_version() {
    local version

    version="$(systemd-run --version)" || die 'Could not determine the systemd version.'
    if [[ ! "$version" =~ ^systemd[[:space:]]+([0-9]+) ]]; then
        die 'Could not parse the systemd version; systemd 254 or newer is required.'
    fi
    if (( 10#${BASH_REMATCH[1]} < 254 )); then
        die 'systemd 254 or newer is required for systemd-run --expand-environment=no.'
    fi
}

preflight_installation() {
    local relative_path source_path target_path id

    for relative_path in "${profile_files[@]}"; do
        source_path="$setup_dir/${files[$relative_path.source]}"
        if [[ ! -f "$source_path" ]]; then
            die "Missing source file: $source_path"
        fi
    done
    if [[ ! -f "$setup_dir/sway/config.d/99-local.conf.example" ]]; then
        die "Missing source file: $setup_dir/sway/config.d/99-local.conf.example"
    fi

    validate_target_directories
    validate_profile_targets
    collect_obsolete_theme_files
    configure_portal_integration

    for id in "${external_files[@]}"; do
        source_path="$setup_dir/${files[$id.source]}"
        target_path="${files[$id.target]}"
        if [[ ! -f "$source_path" ]]; then
            die "Missing source file: $source_path"
        fi
        [[ "${files[$id.action]}" == install ]] || continue
        if [[ -L "$target_path" ]]; then
            handle_external_conflict "$id" \
                'symbolic link not managed by Sway Noir' "$target_path"
        elif [[ -e "$target_path" && ! -f "$target_path" ]]; then
            handle_external_conflict "$id" \
                'non-file path not managed by Sway Noir' "$target_path"
        elif [[ -f "$target_path" ]] &&
             ! files_equal "$source_path" "$target_path" &&
             ! is_managed_external_file "$id" "$source_path" "$target_path"; then
            handle_external_conflict "$id" \
                'existing file not managed by Sway Noir' "$target_path"
        fi
    done

    [[ "$install_login_session" == true ]] || return 0
    for id in "${system_files[@]}"; do
        [[ "${files[$id.action]}" != preserve ]] || continue
        source_path="$setup_dir/${files[$id.source]}"
        target_path="${files[$id.target]}"
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
}

verify_installation() {
    local id relative_path source_path target_path mode

    for relative_path in "${profile_files[@]}"; do
        source_path="$setup_dir/${files[$relative_path.source]}"
        target_path="${files[$relative_path.target]}"
        mode="${files[$relative_path.mode]}"
        if [[ ! -f "$target_path" ]] || ! files_equal "$source_path" "$target_path" ||
           ! file_has_mode "$target_path" "$mode"; then
            die "Verification failed for installed profile file: $target_path"
        fi
    done

    target_path="$profile_root/sway/config.d/99-local.conf"
    if [[ ! -f "$target_path" && ! -L "$target_path" ]]; then
        die "Verification failed for preserved local configuration: $target_path"
    fi

    for id in "${external_files[@]}"; do
        if [[ "${files[$id.action]}" == remove ]]; then
            target_path="${files[$id.target]}"
            if [[ -e "$target_path" || -L "$target_path" ]]; then
                die "Verification failed for removed portal override: $target_path"
            fi
        fi
        [[ "${files[$id.action]}" == install ]] || continue
        source_path="$setup_dir/${files[$id.source]}"
        target_path="${files[$id.target]}"
        if [[ ! -f "$target_path" ]] || ! files_equal "$source_path" "$target_path" ||
           ! file_has_mode "$target_path" "${files[$id.mode]}"; then
            die "Verification failed for installed integration file: $target_path"
        fi
    done

    if [[ "$install_login_session" == true ]]; then
        for id in "${system_files[@]}"; do
            [[ "${files[$id.action]}" == install ]] || continue
            source_path="$setup_dir/${files[$id.source]}"
            target_path="${files[$id.target]}"
            mode="${files[$id.mode]}"
            if [[ ! -f "$target_path" ]] || ! files_equal "$source_path" "$target_path" ||
               ! file_has_mode "$target_path" "$mode"; then
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
