#!/usr/bin/bash
# Backups and interrupted-install reporting; sourced by install.sh.
# shellcheck disable=SC2034,SC2154

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
