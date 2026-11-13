#!/usr/bin/bash
# Registry data is shared across sourced installer modules and inspected here.
# shellcheck disable=SC2034
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=install.sh
source "$repo_root/install.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Registry inspection needs no desktop, user manager, or filesystem writes.
config_root='/fixture/config with spaces'
profile_root="$config_root/sway-noir"
initialize_paths

declare -A seen_ids=() seen_targets=() directory_positions=()
for id in "${profile_files[@]}" "${external_files[@]}" "${system_files[@]}"; do
    [[ -z "${seen_ids[$id]:-}" ]] || fail "duplicate ID: $id"
    seen_ids["$id"]=1
    for field in scope source target mode conflict action; do
        [[ -n "${files[$id.$field]:-}" ]] || fail "missing $field for $id"
    done
    target="${files[$id.target]}"
    [[ "$target" == /* ]] || fail "relative target: $target"
    [[ -z "${seen_targets[$target]:-}" ]] || fail "duplicate target: $target"
    seen_targets["$target"]=1
    [[ -f "$repo_root/${files[$id.source]}" ]] || fail "missing source for $id"
    [[ "${files[$id.mode]}" =~ ^[0-7]{3}$ ]] || fail "invalid file mode for $id"
    case "${files[$id.conflict]}" in replace|preserve|error) ;; *) fail "invalid conflict rule for $id" ;; esac
    case "${files[$id.action]}" in install|preserve) ;; *) fail "invalid initial action for $id" ;; esac
done

for id in "${profile_files[@]}"; do
    [[ "${files[$id.scope]}" == profile && "${files[$id.source]}" == "$id" &&
       "${files[$id.target]}" == "$profile_root/$id" ]] || fail "invalid profile record: $id"
done
for id in "${login_files[@]}"; do
    [[ "${files[$id.scope]}" == system && "${files[$id.mode]}" == 644 &&
       "${files[$id.source]}" == session/sway-noir.desktop ]] || fail "invalid login record: $id"
done
[[ "${files[launcher.mode]}" == 755 ]] || fail 'launcher must be executable'
[[ "$(integration_manifest_key portal)" == external:xdg-desktop-portal/sway-portals.conf ]] ||
    fail 'external checksum key changed'
[[ "$(integration_manifest_key launcher)" == system:/usr/local/bin/start-sway-noir ]] ||
    fail 'system checksum key changed'

for position in "${!profile_directories[@]}"; do
    directory="${profile_directories[$position]}"
    [[ -z "${directory_positions[$directory]:-}" ]] || fail "duplicate directory: $directory"
    directory_positions["$directory"]="$((position + 1))"
done
for directory in "${profile_directories[@]}"; do
    [[ "$directory" != "$profile_root" ]] || continue
    parent="${directory%/*}"
    [[ -n "${directory_positions[$parent]:-}" ]] || fail "missing parent: $parent"
    (( directory_positions[$directory] < directory_positions[$parent] )) || fail 'parent precedes child'
done
for id in "${profile_files[@]}"; do
    parent="${files[$id.target]%/*}"
    [[ -n "${directory_positions[$parent]:-}" ]] || fail "missing target directory for $id"
done

if (register_profile_file start-sway-noir) 2>/dev/null; then fail 'duplicate registry ID accepted'; fi
initialize_paths
[[ "${#seen_ids[@]}" == "$((${#profile_files[@]} + ${#external_files[@]} + ${#system_files[@]}))" ]] ||
    fail 'registry initialization is not repeatable'

printf 'PASS: registry metadata, unique IDs/targets, checksum compatibility and derived directory order\n'
