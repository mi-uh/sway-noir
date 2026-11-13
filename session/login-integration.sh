#!/usr/bin/bash
# Only inspect the existing display manager. Never change its configuration,
# enable/restart a service, or write to an unverified session search directory.
# Variables are shared with install.sh, which sources this file.
# shellcheck disable=SC2154,SC2034

read_sddm_session_dirs() {
    local line section="" key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ "$line" == \[*\] ]]; then
            section="${line:1:${#line}-2}"
        elif [[ "$section" == Wayland || "$section" == WaylandDisplay ]] &&
             [[ "$line" == *=* ]]; then
            key="${line%%=*}"
            key="${key%"${key##*[![:space:]]}"}"
            if [[ "$key" == SessionDir ]]; then
                value="${line#*=}"
                dm_session_dirs="${value#"${value%%[![:space:]]*}"}"
            fi
        fi
    done
}

discover_session_dirs() {
    # The optional root is used only by fixture tests, never by the CLI.
    local root="${1:-}" manager exec_start binary defaults file pid environment entry
    local data_dirs=/usr/local/share:/usr/share
    local -a directories=()
    manager="$(systemctl show --property=Id --value display-manager.service)" ||
        die 'Cannot inspect display-manager.service. Use --profile-only without login integration.'
    exec_start="$(systemctl show --property=ExecStart --value display-manager.service)" ||
        die 'Cannot inspect the display-manager command.'
    if [[ "$exec_start" =~ path=([^\ ;\}]+) ]]; then
        binary="${BASH_REMATCH[1]}"
    else
        die 'Cannot identify the display-manager executable. Use --profile-only.'
    fi
    dm_session_dirs=""
    case "$manager:${binary##*/}" in
        sddm.service:sddm)
            # --example-config prints compiled defaults, NOT the effective config.
            defaults="$("$binary" --example-config)" || die 'Cannot read SDDM defaults.'
            read_sddm_session_dirs <<< "$defaults"
            [[ -n "$dm_session_dirs" ]] || die 'SDDM reports no Wayland session directories.'
            # Match SDDM priority: vendor files, admin files, then sddm.conf.
            for file in "$root"/usr/lib/sddm/sddm.conf.d/* \
                "$root"/etc/sddm.conf.d/* "$root/etc/sddm.conf"; do
                [[ -f "$file" ]] || continue
                [[ -r "$file" ]] || die "Cannot inspect SDDM configuration: $file"
                read_sddm_session_dirs < "$file"
            done
            ;;
        gdm.service:gdm)
            # GDM uses its own system XDG data dirs, not the invoking user's.
            # Reading the daemon environment can require sudo; no files are changed.
            pid="$(systemctl show --property=MainPID --value display-manager.service)" ||
                die 'Cannot inspect GDM MainPID.'
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die 'GDM must be running to verify its session paths.'
            require_command sudo
            require_command cat
            # Decode NUL-delimited process data before storing it in Bash.
            environment="$(sudo cat "$root/proc/$pid/environ" | tr '\0' '\n')" ||
                die 'Cannot read the running GDM environment. Use --profile-only.'
            while IFS= read -r entry; do
                case "$entry" in
                    XDG_DATA_DIRS=*) data_dirs="${entry#*=}" ;;
                esac
            done <<< "$environment"
            IFS=: read -r -a directories <<< "${data_dirs:-/usr/local/share:/usr/share}"
            for entry in "${directories[@]}"; do
                [[ "$entry" == /* ]] || die 'GDM has a relative XDG data directory; cannot verify session paths.'
                dm_session_dirs+="${entry%/}/wayland-sessions,"
            done
            dm_session_dirs="${dm_session_dirs%,}"
            ;;
        *)
            die "Unsupported or custom display manager ($manager). No login files changed; use --profile-only."
            ;;
    esac
    printf 'Verified %s Wayland session search path: %s\n' "$manager" "$dm_session_dirs"
}

path_is_mutable() {
    local path="$1" options
    # Resolve /usr/local -> /var/usrlocal on Atomic, even if the leaf is missing.
    while [[ ! -e "$path" ]]; do
        [[ "$path" != / ]] || return 1
        path="${path%/*}"
        [[ -n "$path" ]] || path=/
    done
    path="$(readlink -f -- "$path")" || return 1
    options="$(findmnt --noheadings --output OPTIONS --target "$path")" || return 1
    [[ -n "$options" && ! "$options" =~ (^|[[:space:],])ro([[:space:],]|$) ]]
}

plan_login_files() {
    local directory id selected="" target_path
    local -a directories=()
    IFS=, read -r -a directories <<< "$dm_session_dirs"
    for directory in "${directories[@]}"; do
        directory="${directory#"${directory%%[![:space:]]*}"}"
        directory="${directory%"${directory##*[![:space:]]}"}"
        directory="${directory%/}"
        # Keep a small, bounded set of destinations: uninstall needs no user-
        # supplied manifest or still-running display manager to find old entries.
        for id in "${login_files[@]}"; do
            target_path="${files[$id.target]}"
            [[ "${target_path%/*}" == "$directory" ]] || continue
            # A higher-priority foreign/symlink entry could shadow the selected
            # destination. Do not silently install an unreachable second entry.
            [[ ! -L "$target_path" ]] || die "Refusing login-session symbolic link: $target_path"
            if [[ -e "$target_path" ]] &&
               { [[ ! -f "$target_path" ]] ||
                  ! is_managed_file "$setup_dir/${files[$id.source]}" "$target_path"; }; then
                die "Refusing unmanaged login-session path: $target_path"
            fi
            if path_is_mutable "$target_path"; then
                login_supported_ids+=("$id")
            fi
        done
    done
    # Keep a working existing entry on mutable Fedora installations.
    for id in "${login_supported_ids[@]}"; do
        target_path="${files[$id.target]}"
        if [[ ! -L "$target_path" && -f "$target_path" ]] &&
           is_managed_file "$setup_dir/${files[$id.source]}" "$target_path"; then
            selected="$id"
            break
        fi
    done
    # Otherwise prefer the Atomic-compatible local data directory, then an
    # explicitly configured /etc path, and finally mutable /usr/share.
    if [[ -z "$selected" ]]; then
        for id in login_local login_etc login_vendor; do
            for directory in "${login_supported_ids[@]}"; do
                if [[ "$id" == "$directory" ]]; then
                    selected="$id"
                    break 2
                fi
            done
        done
    fi
    [[ -n "$selected" ]] ||
        die 'No supported writable Wayland session directory was verified. Use --profile-only; the display-manager configuration was not changed.'
    path_is_mutable "${files[launcher.target]}" || die 'The system launcher path is on a read-only filesystem.'
    files[launcher.action]=install
    files["$selected.action"]=install
    for id in "${login_files[@]}"; do
        [[ "$id" != "$selected" ]] || continue
        target_path="${files[$id.target]}"
        if [[ ! -L "$target_path" && -f "$target_path" ]] &&
           is_managed_file "$setup_dir/${files[$id.source]}" "$target_path"; then
            if path_is_mutable "$target_path"; then
                files["$id.action"]=remove
            else
                warn "Retaining read-only old session entry: $target_path (remove through its owning image/package, not by unlocking /usr)."
            fi
        fi
    done
}

configure_login_session() {
    local -a login_supported_ids=()
    require_command findmnt
    require_command readlink
    require_command tr
    # Production has no fixture root; pass it explicitly for static analysis too.
    discover_session_dirs ""
    plan_login_files
}
