#!/usr/bin/bash
# Remove only verified managed files; sourced by install.sh.
# shellcheck disable=SC2154

uninstall_sway_noir() {
    local id relative_path target_path key
    local managed_files_preserved=false
    local -a managed_system_ids=()

    validate_target_directories

    for id in "${system_files[@]}"; do
        target_path="${files[$id.target]}"
        key="$(integration_manifest_key "$id")"
        if [[ -L "$target_path" ]]; then
            managed_files_preserved=true
            printf 'Preserving symbolic link not managed by Sway Noir: %s\n' "$target_path" >&2
        elif [[ -f "$target_path" ]] &&
              is_managed_file "$setup_dir/${files[$id.source]}" "$target_path"; then
            if path_is_mutable "$target_path"; then
                if integration_file_is_unmodified "$setup_dir/${files[$id.source]}" "$target_path" "$key"; then
                    managed_system_ids+=("$id")
                else
                    managed_files_preserved=true
                    warn "Preserving modified or unverified system file: $target_path"
                fi
            else
                managed_files_preserved=true
                warn "Preserving read-only system file: $target_path (remove through its owning image/package)."
            fi
        elif [[ -e "$target_path" ]]; then
            managed_files_preserved=true
            printf 'Preserving system path not managed by Sway Noir: %s\n' "$target_path" >&2
        fi
    done

    if (( ${#managed_system_ids[@]} > 0 )); then
        require_command sudo
        sudo -v
    fi

    if command -v systemctl >/dev/null 2>&1 &&
       ! systemctl --user stop sway-noir-session.target; then
        printf 'Warning: failed to stop sway-noir-session.target\n' >&2
    fi

    for relative_path in "${profile_files[@]}"; do
        target_path="${files[$relative_path.target]}"
        if profile_path_has_symlink "$relative_path"; then
            managed_files_preserved=true
            printf 'Preserving symbolic link: %s (including linked parent directories)\n' "$target_path" >&2
        elif [[ -f "$target_path" ]] && profile_file_is_unmodified "$relative_path"; then
            rm -f -- "$target_path"
            printf 'Removed: %s\n' "$target_path"
        elif [[ -f "$target_path" ]]; then
            managed_files_preserved=true
            printf 'Preserving modified or unverified profile file: %s\n' "$target_path" >&2
        elif [[ -e "$target_path" ]]; then
            managed_files_preserved=true
            printf 'Preserving unexpected non-file path: %s\n' "$target_path" >&2
        fi
    done

    for id in "${external_files[@]}"; do
        target_path="${files[$id.target]}"
        key="$(integration_manifest_key "$id")"
        if [[ -L "$target_path" ]]; then
            managed_files_preserved=true
            printf 'Preserving symbolic link not managed by Sway Noir: %s\n' "$target_path" >&2
        elif [[ -f "$target_path" ]] &&
             integration_file_is_unmodified "$setup_dir/${files[$id.source]}" "$target_path" "$key"; then
            rm -f -- "$target_path"
            printf 'Removed: %s\n' "$target_path"
        elif [[ -e "$target_path" ]]; then
            managed_files_preserved=true
            printf 'Preserving modified or unverified integration file: %s\n' "$target_path" >&2
        fi
    done

    for id in "${managed_system_ids[@]}"; do
        target_path="${files[$id.target]}"
        key="$(integration_manifest_key "$id")"
        # Recheck after authentication and profile removal, not only in preflight.
        if ! integration_file_is_unmodified "$setup_dir/${files[$id.source]}" "$target_path" "$key"; then
            managed_files_preserved=true
            warn "Preserving changed system file: $target_path"
            continue
        fi
        sudo rm -f -- "$target_path"
        printf 'Removed: %s\n' "$target_path"
    done

    if ! profile_path_has_symlink '.installed-files.sha256' && [[ -f "$profile_manifest" ]] &&
       has_managed_marker "$profile_manifest"; then
        if [[ "$managed_files_preserved" == true ]]; then
            printf 'Preserving checksums for remaining profile or integration files: %s\n' "$profile_manifest"
        else
            rm -f -- "$profile_manifest"
            printf 'Removed: %s\n' "$profile_manifest"
        fi
    elif [[ -e "$profile_manifest" || -L "$profile_manifest" ]]; then
        printf 'Preserving unmanaged profile checksum manifest: %s\n' "$profile_manifest" >&2
    fi

    for target_path in "${profile_directories[@]}" "${external_directories[@]}"; do
        if [[ "$target_path" == "$profile_root" || "$target_path" == "$profile_root/"* ]]; then
            relative_path="${target_path#"$profile_root"}"
            if profile_path_has_symlink "${relative_path#/}"; then
                continue
            fi
        fi
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
