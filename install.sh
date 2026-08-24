#!/usr/bin/bash
set -euo pipefail

readonly setup_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly profile_root="$config_root/sway-noir"
readonly backup_dir="$config_root/sway-setup-backups/$(date +%Y%m%d-%H%M%S)"

files=(
    "start-sway-noir"
    "sway/config"
    "sway/config.d/20-outputs.conf"
    "sway/config.d/40-look.conf"
    "sway/config.d/60-keybindings.conf"
    "sway/config.d/90-bar.conf"
    "sway/config.d/91-autostart.conf"
    "sway/backgrounds/cozy-cyberpunk-room.png"
    "waybar/config.jsonc"
    "waybar/style.css"
    "fuzzel/fuzzel.ini"
    "mako/config"
    "gammastep/config.ini"
    "swaylock/config"
    "swaylock/cozy-cyberpunk-room-lock.png"
)

backup_created=false

for relative_path in "${files[@]}"; do
    source_path="$setup_dir/$relative_path"
    target_path="$profile_root/$relative_path"

    if [[ ! -f "$source_path" ]]; then
        printf 'Missing source file: %s\n' "$source_path" >&2
        exit 1
    fi

    if [[ -e "$target_path" ]]; then
        backup_path="$backup_dir/sway-noir/$relative_path"
        backup_mode="$(stat -c '%a' "$target_path")"
        install -D -p -m "$backup_mode" "$target_path" "$backup_path"
        backup_created=true
    fi

    mode=644
    if [[ "$relative_path" == "start-sway-noir" ]]; then
        mode=755
    fi
    install -D -m "$mode" "$source_path" "$target_path"
done

local_target="$profile_root/sway/config.d/99-local.conf"
if [[ ! -e "$local_target" ]]; then
    install -D -m 644 "$setup_dir/sway/config.d/99-local.conf.example" "$local_target"
fi

if [[ "$backup_created" == true ]]; then
    printf 'Backup: %s\n' "$backup_dir"
fi

printf 'Installed Sway Noir below %s\n' "$profile_root"
printf 'Start from a TTY with: %s/start-sway-noir\n' "$profile_root"
