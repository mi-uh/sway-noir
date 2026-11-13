#!/usr/bin/bash
# Portal, login-file and dark-mode application; sourced by install.sh.
# shellcheck disable=SC2034,SC2154

is_managed_external_file() {
    local id="$1"
    local source_path="$2"
    local target_path="$3"

    if [[ "$id" == portal ]]; then
        portal_config_is_managed "$target_path"
        return
    fi
    if is_managed_file "$source_path" "$target_path"; then
        return 0
    fi

    # Recognize the early project-specific target without an ownership marker.
    if [[ "$id" == session_target ]] &&
       grep -Fqx '[Unit]' "$target_path" &&
       grep -Fq 'Sway Noir' "$target_path" &&
       grep -Fqx 'BindsTo=graphical-session.target' "$target_path"; then
        return 0
    fi
    return 1
}

portal_config_is_managed() {
    local target_path="$1"
    local source_path="$setup_dir/${files[portal.source]}"
    local legacy_checksum target_checksum

    # A marker alone does not authorize replacing a modified fallback.
    [[ ! -L "$target_path" && -f "$target_path" ]] &&
        has_managed_marker "$target_path" || return 1
    if files_equal "$source_path" "$target_path"; then
        return 0
    fi

    # The previous fallback predates the explicit Inhibit setting.
    legacy_checksum="$(grep -Fvx 'org.freedesktop.impl.portal.Inhibit=none' "$source_path" | sha256sum)" ||
        return 1
    target_checksum="$(sha256sum < "$target_path")" || return 1
    [[ "$legacy_checksum" == "$target_checksum" ]]
}

find_portal_configuration() {
    local directory filename candidate
    local -a config_directories data_directories directories

    IFS=: read -r -a config_directories <<< "${XDG_CONFIG_DIRS:-/etc/xdg}"
    IFS=: read -r -a data_directories <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    # Match portals.conf(5) lookup order, excluding our own managed file.
    directories=(
        "$config_root" "${config_directories[@]}" "/etc"
        "${XDG_DATA_HOME:-$HOME/.local/share}"
        "${data_directories[@]}" "/usr/share"
    )
    for directory in "${directories[@]}"; do
        [[ "$directory" == /* ]] || continue
        for filename in sway-portals.conf portals.conf; do
            candidate="$directory/xdg-desktop-portal/$filename"
            [[ "$candidate" != "${files[portal.target]}" ]] || continue
            if [[ "$directory" == "$config_root" && ( -e "$candidate" || -L "$candidate" ) ]]; then
                # Never mask an explicit user-wide choice, even if malformed.
                portal_configuration="$candidate"
                return 0
            fi
            if [[ -f "$candidate" && -r "$candidate" ]] &&
               grep -Eq '^[[:space:]]*\[preferred\][[:space:]]*$' "$candidate"; then
                portal_configuration="$candidate"
                return 0
            fi
        done
    done
    return 1
}

configure_portal_integration() {
    local target_path="${files[portal.target]}"

    if [[ -e "$target_path" || -L "$target_path" ]] &&
       ! portal_config_is_managed "$target_path"; then
        files[portal.action]=preserve
        warn "Preserving existing or modified portal configuration: $target_path"
        return
    fi
    if find_portal_configuration; then
        if [[ -f "$target_path" ]]; then
            files[portal.action]=remove
        else
            files[portal.action]=skip
        fi
    fi
}

handle_external_conflict() {
    local id="$1"
    local description="$2"
    local target_path="$3"

    if [[ "${files[$id.conflict]}" == preserve ]]; then
        files["$id.action"]=preserve
        warn "Preserving $description: $target_path"
        return
    fi
    die "Refusing $description: $target_path"
}

install_external_files() {
    local id source_path target_path relative_target

    for id in "${external_files[@]}"; do
        source_path="$setup_dir/${files[$id.source]}"
        target_path="${files[$id.target]}"
        relative_target="${target_path#"$config_root/"}"
        if [[ "${files[$id.action]}" == remove ]]; then
            # Recheck ownership at removal, not just during preflight.
            if ! portal_config_is_managed "$target_path"; then
                die "Portal override changed after preflight; refusing removal: $target_path"
            fi
            backup_file "$target_path" "$relative_target"
            run "Could not remove obsolete portal override: $target_path" rm -- "$target_path"
            continue
        fi
        [[ "${files[$id.action]}" == install ]] || continue
        if [[ -f "$target_path" ]] && files_equal "$source_path" "$target_path" &&
           file_has_mode "$target_path" "${files[$id.mode]}"; then
            continue
        fi
        if [[ -f "$target_path" ]]; then
            backup_file "$target_path" "$relative_target"
        fi
        run "Could not install $target_path" \
            install -D -m "${files[$id.mode]}" "$source_path" "$target_path"
    done
}

install_login_files() {
    local id source_path target_path mode

    [[ "$install_login_session" == true ]] || return 0
    for id in "${system_files[@]}"; do
        [[ "${files[$id.action]}" == install ]] || continue
        source_path="$setup_dir/${files[$id.source]}"
        target_path="${files[$id.target]}"
        mode="${files[$id.mode]}"
        if [[ -f "$target_path" ]] && files_equal "$source_path" "$target_path" &&
           file_has_mode "$target_path" "$mode"; then
            continue
        fi
        if [[ -f "$target_path" ]]; then
            backup_file "$target_path" "system$target_path"
        fi
        run "Could not install system file $target_path" \
            sudo install -D -m "$mode" "$source_path" "$target_path"
    done
}

remove_old_login_files() {
    local id target_path

    [[ "$install_login_session" == true ]] || return 0
    for id in "${system_files[@]}"; do
        [[ "${files[$id.action]}" == remove ]] || continue
        target_path="${files[$id.target]}"
        backup_file "$target_path" "system$target_path"
        run "Could not remove old session entry: $target_path" sudo rm -f -- "$target_path"
    done
}

read_dark_mode_preferences() {
    dark_color_before=""
    dark_theme_before=""
    [[ "$set_dark_mode" == true ]] || return 0
    require_command gsettings
    if ! dark_color_before="$(gsettings get org.gnome.desktop.interface color-scheme)"; then
        die 'Could not read org.gnome.desktop.interface color-scheme.'
    fi
    if ! dark_theme_before="$(gsettings get org.gnome.desktop.interface gtk-theme)"; then
        die 'Could not read org.gnome.desktop.interface gtk-theme.'
    fi
}

apply_dark_mode() {
    local rollback_path

    [[ "$set_dark_mode" == true ]] || return 0
    if [[ "$dark_color_before" == "'prefer-dark'" &&
          "$dark_theme_before" == "'Adwaita-dark'" ]]; then
        printf 'Dark-mode preferences are already set; no GSettings values changed.\n'
        return
    fi
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
}
