#!/usr/bin/bash
# Installer helpers; no package installation and no running-session requirement.
# Variables are provided by install.sh, which sources this file.
# shellcheck disable=SC2154

detect_package_platform() {
    local ID="" ID_LIKE=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
    fi
    case " $ID $ID_LIKE " in
        *' fedora '*|*' rhel '*) package_platform=fedora ;;
        *' debian '*|*' ubuntu '*) package_platform=debian ;;
        *' arch '*) package_platform=arch ;;
        *) package_platform=unknown ;;
    esac
    atomic_host=false
    [[ ! -e /run/ostree-booted ]] || atomic_host=true
}

unit_available() {
    local directory unit_paths
    # Use systemd's installed search paths without contacting a user manager.
    unit_paths="$(systemd-analyze --user unit-paths)" || return 1
    while IFS= read -r directory; do
        [[ "$directory" == /* && -f "$directory/$1" ]] && return 0
    done <<< "$unit_paths"
    return 1
}

dependency_available() {
    local check="$1" capability="$2" directory result
    local -a data_dirs=()
    case "$check" in
        command) command -v "$capability" >/dev/null 2>&1 ;;
        polkit) find_polkit_agent >/dev/null ;;
        unit) unit_available "$capability" ;;
        portal)
            IFS=: read -r -a data_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
            for directory in "${data_dirs[@]}"; do
                [[ "$directory" == /* ]] || continue
                [[ ! -f "$directory/xdg-desktop-portal/portals/$capability.portal" ]] || return 0
            done
            return 1
            ;;
        audio)
            # Reuse either audio stack; do not demand PipeWire on PulseAudio hosts.
            command -v pulseaudio >/dev/null 2>&1 ||
                unit_available pulseaudio.service ||
                { unit_available pipewire-pulse.service && unit_available pipewire.service &&
                  { unit_available wireplumber.service || unit_available pipewire-media-session.service; }; }
            ;;
        font)
            command -v fc-match >/dev/null 2>&1 || return 1
            result="$(fc-match --format '%{family}' "$capability")" || return 1
            [[ ",$result," == *",$capability,"* ]]
            ;;
        schema)
            command -v gsettings >/dev/null 2>&1 || return 1
            result="$(gsettings list-schemas)" || return 1
            grep -Fqx "$capability" <<< "$result"
            ;;
        *) die "Unknown dependency check: $check" ;;
    esac
}

package_installed() {
    case "$package_platform" in
        fedora) command -v rpm >/dev/null 2>&1 && rpm -q -- "$1" >/dev/null 2>&1 ;;
        debian)
            [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == installed ]]
            ;;
        arch) command -v pacman >/dev/null 2>&1 && pacman -Q -- "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

list_dependencies() {
    local scope check capability fedora debian arch
    [[ -r "$setup_dir/dependencies.list" ]] || die 'Missing dependency definition: dependencies.list'
    printf 'Scope | Capability (check) | Fedora | Debian/Ubuntu | Arch\n'
    while IFS='|' read -r scope check capability fedora debian arch; do
        [[ -n "$scope" && "$scope" != \#* ]] || continue
        printf '%s | %s (%s) | %s | %s | %s\n' \
            "$scope" "$capability" "$check" "$fedora" "$debian" "$arch"
    done < "$setup_dir/dependencies.list"
}

check_runtime_dependencies() {
    local scope check capability fedora debian arch packages package
    local required_missing=false
    local -a required_packages=() feature_packages=() words=() missing_units=()
    local -A seen=()

    [[ -r "$setup_dir/dependencies.list" ]] || die 'Missing dependency definition: dependencies.list'
    detect_package_platform
    while IFS='|' read -r scope check capability fedora debian arch; do
        [[ -n "$scope" && "$scope" != \#* ]] || continue
        [[ "$scope" != dark || "$set_dark_mode" == true ]] || continue
        if dependency_available "$check" "$capability"; then
            continue
        fi
        if [[ "$scope" == feature ]]; then
            if [[ "$check" == command || "$check" == polkit ]]; then
                warn "Optional command not found: $capability. This feature is unavailable with the default configuration; the desktop can still be installed."
            else
                printf 'Optional functionality unavailable: %s (%s)\n' "$capability" "$check" >&2
            fi
        else
            printf 'Required dependency missing: %s (%s)\n' "$capability" "$check" >&2
            required_missing=true
            [[ "$check" != unit ]] || missing_units+=("$capability")
        fi
        case "$package_platform" in
            fedora) packages="$fedora" ;;
            debian) packages="$debian" ;;
            arch) packages="$arch" ;;
            *)
                printf '  Package hints: Fedora: %s; Debian/Ubuntu: %s; Arch: %s\n' \
                    "$fedora" "$debian" "$arch" >&2
                continue
                ;;
        esac
        read -r -a words <<< "$packages"
        for package in "${words[@]}"; do
            if package_installed "$package"; then
                printf '  %s is already installed; check its configuration/files.\n' "$package" >&2
            elif [[ -z "${seen[$package]:-}" ]]; then
                seen[$package]=1
                if [[ "$scope" == feature ]]; then
                    feature_packages+=("$package")
                else
                    required_packages+=("$package")
                fi
            fi
        done
    done < "$setup_dir/dependencies.list"

    print_package_hint 'Required packages' "${required_packages[@]}"
    print_package_hint 'Optional feature packages (choose only what you use)' "${feature_packages[@]}"
    if (( ${#missing_units[@]} > 0 )); then
        printf 'Error: required desktop portal user units are missing:\n' >&2
        printf '  %s\n' "${missing_units[@]}" >&2
    fi
    if [[ "$required_missing" == true ]]; then
        printf 'No files changed. Install missing requirements manually, then rerun.\n' >&2
        return 1
    fi
    check_systemd_version
}

print_package_hint() {
    local description="$1"
    shift
    (( $# > 0 )) || return 0
    printf '%s; suggested command (NOT executed):\n  sudo' "$description" >&2
    case "$package_platform" in
        fedora)
            if [[ "$atomic_host" == true ]]; then
                printf ' rpm-ostree install' >&2
            else
                printf ' dnf install' >&2
            fi
            ;;
        debian) printf ' apt install' >&2 ;;
        arch) printf ' pacman -S --needed' >&2 ;;
    esac
    printf ' %s' "$@" >&2
    printf '\n' >&2
    if [[ "$atomic_host" == true ]]; then
        printf 'On Atomic, use host packages only where needed; reboot into the new deployment before rerunning.\n' >&2
    fi
}

# Shared with the optional desktop agent; no installer checks run when sourced.
find_polkit_agent() {
    if command -v lxqt-policykit-agent >/dev/null 2>&1; then
        command -v lxqt-policykit-agent
    elif [[ -x /usr/libexec/lxqt-policykit-agent ]]; then
        printf '%s\n' /usr/libexec/lxqt-policykit-agent
    else
        return 1
    fi
}
