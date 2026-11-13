#!/usr/bin/bash
# Profile installation, ownership and retired themes; sourced by install.sh.
# shellcheck disable=SC2154

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

file_has_mode() {
    local actual_mode

    actual_mode="$(stat -c '%a' -- "$1")" || die "Could not read file mode: $1"
    [[ "$actual_mode" == "$2" ]]
}

install_profile_files() {
    local relative_path source_path target_path mode local_target

    for relative_path in "${profile_files[@]}"; do
        source_path="$setup_dir/${files[$relative_path.source]}"
        target_path="${files[$relative_path.target]}"
        mode="${files[$relative_path.mode]}"
        if [[ -f "$target_path" ]] && files_equal "$source_path" "$target_path" &&
           file_has_mode "$target_path" "$mode"; then
            continue
        fi
        if [[ -e "$target_path" ]]; then
            backup_file "$target_path" "sway-noir/$relative_path"
        fi
        run "Could not install $target_path" \
            install -D -m "$mode" "$source_path" "$target_path"
    done

    local_target="$profile_root/sway/config.d/99-local.conf"
    if [[ ! -e "$local_target" && ! -L "$local_target" ]]; then
        run "Could not create $local_target" \
            install -D -m 644 "$setup_dir/sway/config.d/99-local.conf.example" "$local_target"
    fi
}

write_profile_manifest() {
    local temporary_manifest

    temporary_manifest="$(mktemp "$profile_root/.installed-files.XXXXXX")" ||
        die 'Could not create the installed profile checksum manifest.'
    if ! (
        printf '%s\n' "$managed_marker" &&
        cd -- "$profile_root" &&
        sha256sum -- "${profile_files[@]}" &&
        write_integration_checksums
    ) > "$temporary_manifest"; then
        rm -f -- "$temporary_manifest"
        die 'Could not record the installed profile checksums.'
    fi
    run 'Could not save the installed profile checksum manifest.' \
        mv -f -- "$temporary_manifest" "$profile_manifest"
}

manifest_checksum_for() {
    local key="$1" checksum recorded_path

    [[ ! -L "$profile_manifest" && -f "$profile_manifest" ]] &&
        has_managed_marker "$profile_manifest" || return 1
    while read -r checksum recorded_path; do
        if [[ "$recorded_path" == "$key" && "$checksum" =~ ^[[:xdigit:]]{64}$ ]]; then
            printf '%s\n' "$checksum"
            return 0
        fi
    done < "$profile_manifest"
    return 1
}

write_integration_checksums() {
    local id key target_path action checksum

    printf '# Integration checksums v1.\n' || return 1
    for id in "${external_files[@]}" "${system_files[@]}"; do
        key="$(integration_manifest_key "$id")" || return 1
        target_path="${files[$id.target]}"
        action="${files[$id.action]}"
        if [[ "$action" == install ]]; then
            checksum="$(sha256sum < "$target_path")" || return 1
            checksum="${checksum%% *}"
        elif [[ "$action" == preserve ]] && checksum="$(manifest_checksum_for "$key")"; then
            # Profile-only updates must not adopt edited login files as the
            # new removal baseline, or forget their installed checksums.
            :
        else
            continue
        fi
        printf '%s  %s\n' "$checksum" "$key" || return 1
    done
}

integration_file_is_unmodified() {
    local source_path="$1" target_path="$2" key="$3" checksum actual_checksum

    [[ ! -L "$target_path" && -f "$target_path" ]] || return 1
    if [[ -e "$profile_manifest" || -L "$profile_manifest" ]]; then
        [[ ! -L "$profile_manifest" && -f "$profile_manifest" ]] &&
            has_managed_marker "$profile_manifest" || return 1
        if grep -Fqx '# Integration checksums v1.' "$profile_manifest"; then
            checksum="$(manifest_checksum_for "$key")" || return 1
            actual_checksum="$(sha256sum < "$target_path")" || return 1
            [[ "${actual_checksum%% *}" == "$checksum" ]]
            return
        fi
    fi

    # Older installs have no integration baseline. A marker alone never proves
    # unchanged contents; accept only exact current or known legacy copies.
    if [[ "$source_path" == "$setup_dir/${files[portal.source]}" ]]; then
        portal_config_is_managed "$target_path"
    else
        files_equal "$source_path" "$target_path" || is_exact_legacy_file "$source_path" "$target_path"
    fi
}

collect_obsolete_theme_files() {
    local checksum relative_path actual_checksum

    # The previous manifest, never a theme name, proves ownership.
    [[ -f "$profile_manifest" && ! -L "$profile_manifest" ]] &&
        has_managed_marker "$profile_manifest" || return 0
    while read -r checksum relative_path; do
        [[ "$checksum" =~ ^[[:xdigit:]]{64}$ && "$relative_path" == themes/* &&
           "/$relative_path/" != */../* && "/$relative_path/" != */./* ]] || continue
        [[ ! -e "$setup_dir/$relative_path" && -f "$profile_root/$relative_path" ]] || continue
        if profile_path_has_symlink "$relative_path"; then continue; fi
        actual_checksum="$(sha256sum < "$profile_root/$relative_path")" || continue
        if [[ "${actual_checksum%% *}" != "$checksum" ]]; then
            warn "Preserving modified obsolete theme file: $profile_root/$relative_path"
            continue
        fi
        obsolete_theme_files+=("$relative_path")
        obsolete_theme_checksums+=("$checksum")
    done < "$profile_manifest"
}

remove_obsolete_theme_files() {
    local index relative_path target_path actual_checksum directory

    for index in "${!obsolete_theme_files[@]}"; do
        relative_path="${obsolete_theme_files[$index]}"
        target_path="$profile_root/$relative_path"
        # Recheck before deletion; files may change after preflight.
        if profile_path_has_symlink "$relative_path" || [[ ! -f "$target_path" ]]; then
            warn "Preserving changed obsolete theme path: $target_path"
            continue
        fi
        actual_checksum="$(sha256sum < "$target_path")" || die "Could not check $target_path"
        if [[ "${actual_checksum%% *}" != "${obsolete_theme_checksums[$index]}" ]]; then
            warn "Preserving modified obsolete theme file: $target_path"
            continue
        fi
        backup_file "$target_path" "sway-noir/$relative_path"
        run "Could not remove obsolete theme file: $target_path" rm -- "$target_path"
        directory="${target_path%/*}"
        while [[ "$directory" == "$profile_root/themes/"* ]]; do
            rmdir -- "$directory" 2>/dev/null || break
            directory="${directory%/*}"
        done
    done
}

profile_file_is_unmodified() {
    local relative_path="$1"
    local checksum recorded_path actual_checksum

    if [[ -e "$profile_manifest" || -L "$profile_manifest" ]]; then
        # Invalid or incomplete manifests never authorize deletion.
        [[ ! -L "$profile_manifest" && -f "$profile_manifest" ]] &&
            has_managed_marker "$profile_manifest" || return 1
        while read -r checksum recorded_path; do
            if [[ "$recorded_path" == "$relative_path" &&
                  "$checksum" =~ ^[[:xdigit:]]{64}$ ]]; then
                actual_checksum="$(sha256sum < "$profile_root/$relative_path")" || return 1
                [[ "${actual_checksum%% *}" == "$checksum" ]]
                return
            fi
        done < "$profile_manifest"
        return 1
    fi

    # Older installations have no manifest; preserve anything not identical.
    files_equal "$setup_dir/$relative_path" "$profile_root/$relative_path"
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

    is_exact_legacy_file "$source_path" "$target_path"
}

is_exact_legacy_file() {
    local source_path="$1" target_path="$2" source_without_marker target_hash

    # Accept exact older copies predating the marker, not unrelated files.
    if ! source_without_marker="$(grep -Fvx "$managed_marker" "$source_path" | sha256sum)"; then
        die "Could not calculate the legacy checksum for $source_path"
    fi
    if ! target_hash="$(sha256sum < "$target_path")"; then
        die "Could not calculate the checksum for $target_path"
    fi
    [[ "$source_without_marker" == "$target_hash" ]]
}
