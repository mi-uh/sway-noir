#!/usr/bin/bash
# Callbacks are invoked by sourced helpers; probe subshells isolate their state.
# shellcheck disable=SC2329,SC2030,SC2031
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp_base="${TMPDIR:-/tmp}"
if [[ -z "${TMPDIR:-}" && -w /tmp/opencode ]]; then temp_base=/tmp/opencode; fi
test_root="$(mktemp -d "$temp_base/sway-noir-preflight.XXXXXX")"
readonly repo_root test_root
trap 'rm -rf -- "$test_root"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
excludes() { if grep -Fq -- "$2" "$1"; then fail "$1 unexpectedly contains: $2"; fi; }

# Source the real installer without executing main. Only the system boundary
# (service metadata, mount flags, sudo) and host dependency state are mocked.
# shellcheck source=install.sh
source "$repo_root/install.sh"

rename_function() {
    local definition
    definition="$(declare -f "$1")"
    eval "${definition/#$1/$2}"
}
rename_function initialize_paths initialize_default_paths
rename_function discover_session_dirs discover_fixture_session_dirs
rename_function dependency_available actual_dependency_available
rename_function unit_available actual_unit_available
rename_function detect_package_platform actual_detect_package_platform
rename_function verify_installation verify_default_installation

initialize_paths() {
    initialize_default_paths
    local id
    for id in "${system_files[@]}"; do
        files["$id.target"]="$fixture_root${files[$id.target]}"
    done
}
discover_session_dirs() { discover_fixture_session_dirs "$fixture_root"; }

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$fixture_root/commands.log"
    case "$*" in
        'show --property=Id --value display-manager.service') printf '%s\n' "$fixture_manager.service" ;;
        'show --property=ExecStart --value display-manager.service')
            printf '{ path=%s/bin/%s ; argv[]=%s ; }\n' "$fixture_root" "$fixture_manager" "$fixture_manager"
            ;;
        'show --property=MainPID --value display-manager.service') printf '123\n' ;;
        --user*) return 0 ;;
        *) fail "unexpected systemctl call: $*" ;;
    esac
}
systemd-run() { printf 'systemd 254 (254.1)\n'; }
systemd-analyze() { printf '%s\n' "$XDG_CONFIG_HOME/systemd/user"; }
findmnt() {
    case "${*: -1}" in
        "$fixture_root/usr/share"*)
            if [[ "$readonly_usr" == true ]]; then printf 'ro,relatime\n'; else printf 'rw,relatime\n'; fi
            ;;
        "$fixture_root"*) printf 'rw,relatime\n' ;;
        *) fail "mount check escaped fixture: $*" ;;
    esac
}
sudo() {
    printf 'sudo %s\n' "$*" >> "$fixture_root/commands.log"
    [[ "$1" != -v ]] || return 0
    case "$1" in
        install|rm|cat) ;;
        *) fail "unexpected privileged command: $*" ;;
    esac
    [[ "${*: -1}" == "$fixture_root/"* ]] || fail "sudo escaped fixture: $*"
    command "$@"
}

detect_package_platform() {
    package_platform="$fixture_platform"
    atomic_host="$fixture_atomic"
}
dependency_available() {
    [[ "|$missing_capabilities|" != *"|$2|"* ]]
}
rpm() {
    [[ "|$installed_packages|" == *"|${*: -1}|"* ]]
}
# Any accidental package operation fails the test rather than reaching the host.
dnf() { fail 'automatic package installation'; }
rpm-ostree() { fail 'automatic package layering'; }
apt() { fail 'automatic package installation'; }
pacman() { [[ "$1" == -Q ]] || fail 'automatic package installation'; return 1; }
dpkg-query() { return 1; }

prepare_fixture() {
    fixture_root="$test_root/$1"
    fixture_manager=sddm
    fixture_platform=fedora
    fixture_atomic=false
    readonly_usr=false
    missing_capabilities=""
    installed_packages=""
    export FIXTURE_ROOT="$fixture_root"
    export HOME="$fixture_root/home"
    export XDG_CONFIG_HOME="$HOME/config"
    install -d "$fixture_root/bin" "$fixture_root/usr/share/wayland-sessions" \
        "$fixture_root/var/usrlocal" "$fixture_root/etc" "$fixture_root/proc/123" "$HOME"
    ln -s ../var/usrlocal "$fixture_root/usr/local"
    cat > "$fixture_root/bin/sddm" <<'EOF'
#!/usr/bin/bash
[[ "$1" == --example-config ]] || exit 1
printf '[Wayland]\nSessionDir=%s/usr/local/share/wayland-sessions,%s/usr/share/wayland-sessions\n' "$FIXTURE_ROOT" "$FIXTURE_ROOT"
EOF
    chmod 755 "$fixture_root/bin/sddm"
}

# Dependencies: only missing packages, deduplication, installed capabilities
# with damaged configuration, optional vs required, and platform-specific hints.
prepare_fixture dependencies
missing_capabilities='sway|swaymsg|foot|brightnessctl'
installed_packages=foot
if (main --check-deps) > "$fixture_root/check.log" 2>&1; then
    fail 'missing required dependencies did not fail'
fi
contains "$fixture_root/check.log" 'sudo dnf install sway'
contains "$fixture_root/check.log" 'sudo dnf install brightnessctl'
contains "$fixture_root/check.log" 'foot is already installed'
excludes "$fixture_root/check.log" 'install sway sway'
excludes "$fixture_root/check.log" 'install sway foot'
[[ ! -e "$XDG_CONFIG_HOME" ]] || fail 'dependency inspection changed files'

fixture_atomic=true
missing_capabilities=foot
installed_packages=""
if (main --check-deps) > "$fixture_root/atomic.log" 2>&1; then fail 'Atomic missing dependency accepted'; fi
contains "$fixture_root/atomic.log" 'sudo rpm-ostree install foot'
contains "$fixture_root/atomic.log" 'reboot into the new deployment'
excludes "$fixture_root/atomic.log" 'dnf install'
missing_capabilities=brightnessctl
(main --check-deps) > "$fixture_root/optional.log" 2>&1
excludes "$fixture_root/optional.log" 'Required dependency missing'
missing_capabilities=gsettings
(main --check-deps) > "$fixture_root/dark-not-requested.log" 2>&1
excludes "$fixture_root/dark-not-requested.log" 'gsettings'
if (main --check-deps --set-dark-mode) > "$fixture_root/dark-requested.log" 2>&1; then fail 'dark requirement ignored'; fi
contains "$fixture_root/dark-requested.log" 'Required dependency missing: gsettings'
[[ ! -e "$XDG_CONFIG_HOME" ]] || fail 'dark dependency inspection changed settings/profile'
for fixture_platform in debian arch unknown; do
    fixture_atomic=false
    missing_capabilities=foot
    if (main --check-deps) > "$fixture_root/$fixture_platform.log" 2>&1; then fail 'missing terminal accepted'; fi
done
contains "$fixture_root/debian.log" 'sudo apt install foot'
contains "$fixture_root/arch.log" 'sudo pacman -S --needed foot'
contains "$fixture_root/unknown.log" 'Package hints: Fedora: foot'
excludes "$fixture_root/unknown.log" 'sudo'

# Actual non-command probes, without an audio server, D-Bus, or user manager.
(
    prepare_fixture probes
    install -D -m 644 /dev/null "$XDG_CONFIG_HOME/systemd/user/sway-noir-probe.service"
    actual_unit_available sway-noir-probe.service || fail 'offline user unit lookup failed'
    # These mocks are called through the dynamically renamed dependency helper.
    # shellcheck disable=SC2317
    unit_available() { [[ "|$available_units|" == *"|$1|"* ]]; }
    available_units='pipewire.service|pipewire-pulse.service|wireplumber.service'
    actual_dependency_available audio ignored || fail 'existing PipeWire stack rejected'
    available_units=pulseaudio.service
    actual_dependency_available audio ignored || fail 'existing PulseAudio stack rejected'
    available_units=pipewire.service
    if actual_dependency_available audio ignored; then fail 'incomplete audio stack accepted'; fi
    available_units=xdg-desktop-portal.service
    actual_dependency_available unit xdg-desktop-portal.service || fail 'portal unit rejected'
    export XDG_DATA_DIRS="$fixture_root/data"
    install -D -m 644 /dev/null "$XDG_DATA_DIRS/xdg-desktop-portal/portals/wlr.portal"
    actual_dependency_available portal wlr || fail 'installed portal backend rejected'
    if actual_dependency_available portal gtk; then fail 'missing portal backend accepted'; fi
    # shellcheck disable=SC2317
    fc-match() { printf 'DejaVu Sans'; }
    if actual_dependency_available font 'IBM Plex Sans'; then fail 'font fallback mistaken for Plex'; fi
    # shellcheck disable=SC2317
    fc-match() { printf 'IBM Plex Sans'; }
    actual_dependency_available font 'IBM Plex Sans' || fail 'Plex rejected'
    # shellcheck disable=SC2317
    gsettings() { printf 'org.example.unrelated\n'; }
    if actual_dependency_available schema org.gnome.desktop.interface; then fail 'absent schema accepted'; fi
    # shellcheck disable=SC2317
    gsettings() { printf 'org.gnome.desktop.interface\n'; }
    actual_dependency_available schema org.gnome.desktop.interface || fail 'schema rejected'
)

# Registry consumers must not depend on list positions. A newly registered file
# also drives installation, mode verification, checksums and uninstall directly.
(
    prepare_fixture registry-order
    rename_function initialize_file_registry initialize_original_file_registry
    # The sourced initialize_paths helper invokes this replacement indirectly.
    # shellcheck disable=SC2317
    initialize_file_registry() {
        initialize_original_file_registry
        register_profile_file README.md 600
        external_files=(portal session_target)
        system_files=(login_etc launcher login_vendor login_local)
        login_files=(login_etc login_vendor login_local)
    }
    (main --login-session) > "$fixture_root/install.log" 2>&1
    [[ -f "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop" ]] ||
        fail 'reordered registry selected the wrong login destination'
    [[ "$(stat -c '%a' "$XDG_CONFIG_HOME/sway-noir/README.md")" == 600 ]] ||
        fail 'new registry file or its mode was ignored'
    (main --uninstall --yes) > "$fixture_root/uninstall.log" 2>&1
    [[ ! -e "$XDG_CONFIG_HOME/sway-noir/README.md" &&
       ! -e "$XDG_CONFIG_HOME/systemd/user/sway-noir-session.target" &&
       ! -e "$fixture_root/usr/local/bin/start-sway-noir" &&
       ! -e "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop" ]] ||
        fail 'reordered or extended registry left unchanged files behind'
)

# New Atomic login integration: resolve /usr/local symlink, never touch /usr/share.
prepare_fixture atomic-login
readonly_usr=true
(main --login-session) > "$fixture_root/install.log" 2>&1
contains "$fixture_root/install.log" 'Verified sddm.service'
[[ -x "$fixture_root/usr/local/bin/start-sway-noir" ]] || fail 'launcher not executable'
[[ -f "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop" ]] || fail 'local session not installed'
[[ ! -e "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop" ]] || fail 'wrote immutable /usr/share'
(main --login-session) > "$fixture_root/update.log" 2>&1
(main --profile-only) > "$fixture_root/profile-only.log" 2>&1
excludes "$fixture_root/profile-only.log" 'Verified sddm.service'
[[ -f "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop" ]] || fail 'profile-only changed login files'
(main --uninstall --yes) > "$fixture_root/uninstall.log" 2>&1
[[ ! -e "$fixture_root/usr/local/bin/start-sway-noir" ]] || fail 'launcher not uninstalled'
[[ ! -e "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop" ]] || fail 'new session not uninstalled'

# Modified integration files must survive repeated uninstalls, including after a
# profile-only update that leaves the system login integration untouched.
for integration in target launcher desktop; do
    prepare_fixture "modified-$integration"
    (main --login-session) > "$fixture_root/install.log" 2>&1
    case "$integration" in
        target) modified_target="$XDG_CONFIG_HOME/systemd/user/sway-noir-session.target" ;;
        launcher) modified_target="$fixture_root/usr/local/bin/start-sway-noir" ;;
        desktop) modified_target="$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop" ;;
    esac
    if [[ "$integration" != target ]]; then
        printf '\n# personal customization\n' >> "$modified_target"
        (main --profile-only) > "$fixture_root/update.log" 2>&1
    else
        printf '\n# personal customization\n' >> "$modified_target"
    fi
    modified_checksum="$(sha256sum < "$modified_target")"
    for attempt in 1 2; do
        (main --uninstall --yes) > "$fixture_root/uninstall-$attempt.log" 2>&1
        [[ -f "$modified_target" && "$(sha256sum < "$modified_target")" == "$modified_checksum" ]] ||
            fail "modified $integration was not preserved on uninstall $attempt"
        [[ -f "$XDG_CONFIG_HOME/sway-noir/.installed-files.sha256" ]] ||
            fail 'remaining integration lost its checksum baseline'
    done
done

# Legacy installs without integration checksums must not trust a marker alone.
prepare_fixture modified-legacy-integrations
(main --login-session) > "$fixture_root/install.log" 2>&1
rm -- "$XDG_CONFIG_HOME/sway-noir/.installed-files.sha256"
legacy_targets=(
    "$XDG_CONFIG_HOME/systemd/user/sway-noir-session.target"
    "$fixture_root/usr/local/bin/start-sway-noir"
    "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop"
)
for target in "${legacy_targets[@]}"; do
    printf '\n# legacy personal customization\n' >> "$target"
done
legacy_before="$(sha256sum -- "${legacy_targets[@]}")"
(main --uninstall --yes) > "$fixture_root/uninstall.log" 2>&1
[[ "$(sha256sum -- "${legacy_targets[@]}")" == "$legacy_before" ]] ||
    fail 'modified legacy integrations were not preserved'

# Incomplete/invalid new integration records must not fall back to the checkout.
for record in missing invalid; do
    prepare_fixture "integration-record-$record"
    (main --login-session) > "$fixture_root/install.log" 2>&1
    manifest="$XDG_CONFIG_HOME/sway-noir/.installed-files.sha256"
    grep -Fv 'external:systemd/user/sway-noir-session.target' "$manifest" > "$manifest.tmp"
    if [[ "$record" == invalid ]]; then
        printf 'invalid-checksum  external:systemd/user/sway-noir-session.target\n' >> "$manifest.tmp"
    fi
    mv -- "$manifest.tmp" "$manifest"
    for attempt in 1 2; do
        (main --uninstall --yes) > "$fixture_root/uninstall-$attempt.log" 2>&1
        [[ -f "$XDG_CONFIG_HOME/systemd/user/sway-noir-session.target" && -f "$manifest" ]] ||
            fail "$record integration checksum authorized removal"
    done
done

# Mutable Fedora keeps its existing managed legacy entry and removes it on uninstall.
prepare_fixture mutable-legacy
install -m 644 "$repo_root/session/sway-noir.desktop" "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop"
(main --login-session) > "$fixture_root/update.log" 2>&1
[[ -f "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop" ]] || fail 'legacy session lost'
[[ ! -e "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop" ]] || fail 'unnecessary migration'
(main --uninstall --yes) > "$fixture_root/uninstall.log" 2>&1
[[ ! -e "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop" ]] || fail 'legacy entry not uninstalled'

# Legacy unmarked exact copies remain owned; unrelated files and links survive.
prepare_fixture uninstall-ownership
install -d "$fixture_root/usr/local/bin" "$fixture_root/etc/wayland-sessions"
grep -Fvx '# Managed by Sway Noir.' "$repo_root/session/sway-noir.desktop" > "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop"
install -m 644 "$repo_root/README.md" "$fixture_root/etc/wayland-sessions/sway-noir.desktop"
ln -s "$repo_root/README.md" "$fixture_root/usr/local/bin/start-sway-noir"
(main --uninstall --yes) > "$fixture_root/uninstall.log" 2>&1
[[ ! -e "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop" ]] || fail 'unmarked legacy entry retained'
[[ -f "$fixture_root/etc/wayland-sessions/sway-noir.desktop" ]] || fail 'foreign session removed'
[[ -L "$fixture_root/usr/local/bin/start-sway-noir" ]] || fail 'foreign symlink removed'

# Config priority, explicit /etc support, migration after a search-path change.
prepare_fixture sddm-overrides
install -d "$fixture_root/usr/lib/sddm/sddm.conf.d" "$fixture_root/etc/sddm.conf.d" "$fixture_root/etc/wayland-sessions"
printf '[Wayland]\nSessionDir=/unsupported/vendor\n' > "$fixture_root/usr/lib/sddm/sddm.conf.d/10-vendor.conf"
printf '[Wayland]\nSessionDir=/unsupported/admin\n' > "$fixture_root/etc/sddm.conf.d/20-admin.conf"
printf '[X11]\nSessionDir=/wrong\n[Wayland]\nSessionDir= %s/etc/wayland-sessions # comment\n' "$fixture_root" > "$fixture_root/etc/sddm.conf"
install -m 644 "$repo_root/session/sway-noir.desktop" "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop"
(main --login-session) > "$fixture_root/install.log" 2>&1
[[ -f "$fixture_root/etc/wayland-sessions/sway-noir.desktop" ]] || fail 'effective /etc path ignored'
[[ ! -e "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop" ]] || fail 'superseded entry not removed'
[[ -n "$(find "$XDG_CONFIG_HOME/sway-setup-backups" -path '*/system/*/sway-noir.desktop' -print -quit)" ]] || fail 'migration not backed up'
fixture_manager=unknown
(main --uninstall --yes) > "$fixture_root/uninstall.log" 2>&1
[[ ! -e "$fixture_root/etc/wayland-sessions/sway-noir.desktop" ]] || fail 'uninstall depends on old display manager'

# Do not remove a legacy entry if the replacement has not verified successfully.
prepare_fixture failed-migration
install -d "$fixture_root/etc/wayland-sessions"
printf '[Wayland]\nSessionDir=%s/etc/wayland-sessions\n' "$fixture_root" > "$fixture_root/etc/sddm.conf"
install -m 644 "$repo_root/session/sway-noir.desktop" "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop"
if (
    verify_installation() { die 'injected verification failure'; }
    main --login-session
) > "$fixture_root/install.log" 2>&1; then fail 'verification failure was ignored'; fi
contains "$fixture_root/install.log" 'Installation stopped after file changes had begun'
[[ -f "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop" ]] || fail 'old entry removed before successful verification'

# Failed verification/cleanup must retain the previous ownership manifest so a
# retry can still retire unchanged bundled themes safely.
for failure in verification cleanup; do
    prepare_fixture "failed-update-$failure"
    (main --profile-only) > "$fixture_root/initial.log" 2>&1
    obsolete_path="$XDG_CONFIG_HOME/sway-noir/themes/retired/theme.conf"
    install -D -m 644 /dev/null "$obsolete_path"
    printf 'name=Retired\n' > "$obsolete_path"
    manifest="$XDG_CONFIG_HOME/sway-noir/.installed-files.sha256"
    (
        cd "$XDG_CONFIG_HOME/sway-noir"
        sha256sum themes/retired/theme.conf
    ) >> "$manifest"
    manifest_before="$(sha256sum < "$manifest")"
    if (
        if [[ "$failure" == verification ]]; then
            verify_installation() { die 'injected verification failure'; }
        else
            # Inject failure only for the unprivileged retired-theme removal.
            # shellcheck disable=SC2032
            rm() {
                [[ "${*: -1}" != "$obsolete_path" ]] || return 1
                command rm "$@"
            }
        fi
        main --profile-only
    ) > "$fixture_root/failed.log" 2>&1; then
        fail "injected $failure failure was ignored"
    fi
    contains "$fixture_root/failed.log" 'Installation stopped after file changes had begun'
    [[ "$(sha256sum < "$manifest")" == "$manifest_before" ]] ||
        fail "$failure failure replaced the previous ownership manifest"
    [[ -f "$obsolete_path" ]] || fail "$failure failure lost the obsolete theme"
    (main --profile-only) > "$fixture_root/retry.log" 2>&1
    [[ ! -e "${obsolete_path%/*}" ]] || fail "$failure retry did not retire the theme"
    excludes "$manifest" 'themes/retired/'
done

# Repair equal-content system files too, preserving their old modes in backups.
prepare_fixture login-mode-repair
(main --login-session) > "$fixture_root/initial.log" 2>&1
chmod 644 "$fixture_root/usr/local/bin/start-sway-noir"
chmod 755 "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop"
(main --login-session) > "$fixture_root/repair.log" 2>&1
[[ "$(stat -c '%a' "$fixture_root/usr/local/bin/start-sway-noir")" == 755 ]] ||
    fail 'equal-content system launcher remained non-executable'
[[ "$(stat -c '%a' "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop")" == 644 ]] ||
    fail 'equal-content login entry retained executable permissions'
backup_launcher="$(find "$XDG_CONFIG_HOME/sway-setup-backups" -path '*/bin/start-sway-noir' -print -quit)"
[[ -f "$backup_launcher" && "$(stat -c '%a' "$backup_launcher")" == 644 ]] ||
    fail 'mode repair did not back up the original launcher permissions'

# Post-install verification must reject incorrect modes even with equal hashes.
for damaged_file in profile integration system; do
    prepare_fixture "verify-mode-$damaged_file"
    if (
        verify_installation() {
            case "$damaged_file" in
                profile) chmod 644 "$profile_root/start-sway-noir" ;;
                integration) chmod 755 "$config_root/systemd/user/sway-noir-session.target" ;;
                system) chmod 644 "${files[launcher.target]}" ;;
            esac
            verify_default_installation
        }
        main --login-session
    ) > "$fixture_root/install.log" 2>&1; then
        fail "verification accepted incorrect $damaged_file file permissions"
    fi
    contains "$fixture_root/install.log" 'Verification failed for installed'
    [[ ! -e "$XDG_CONFIG_HOME/sway-noir/.installed-files.sha256" ]] ||
        fail 'failed initial verification published a success manifest'
done

# Unverified paths and managers stop before any profile or login file changes.
for scenario in unknown-manager unsupported-path readonly-only unmanaged-selected symlink-selected; do
    prepare_fixture "$scenario"
    case "$scenario" in
        unknown-manager) fixture_manager=unknown ;;
        unsupported-path) printf '[Wayland]\nSessionDir=/custom/unsupported\n' > "$fixture_root/etc/sddm.conf" ;;
        readonly-only)
            readonly_usr=true
            printf '[Wayland]\nSessionDir=%s/usr/share/wayland-sessions\n' "$fixture_root" > "$fixture_root/etc/sddm.conf"
            ;;
        unmanaged-selected)
            install -D -m 644 "$repo_root/README.md" "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop"
            ;;
        symlink-selected)
            install -d "$fixture_root/usr/local/share/wayland-sessions"
            ln -s "$repo_root/README.md" "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop"
            ;;
    esac
    if (main --login-session) > "$fixture_root/install.log" 2>&1; then fail "$scenario was accepted"; fi
    [[ ! -e "$XDG_CONFIG_HOME/sway-noir" ]] || fail "$scenario changed profile files"
    excludes "$fixture_root/commands.log" 'sudo install'
done

# Only the known Atomic redirect is allowed; other system links must not be followed.
for scenario in linked-login-directory unexpected-local-redirect linked-atomic-destination; do
    prepare_fixture "$scenario"
    outside="$fixture_root/outside"
    install -D -m 755 "$repo_root/session/start-sway-noir" "$outside/bin/start-sway-noir"
    install -D -m 644 "$repo_root/session/sway-noir.desktop" \
        "$outside/share/wayland-sessions/sway-noir.desktop"
    install -m 644 "$repo_root/session/sway-noir.desktop" "$outside/sway-noir.desktop"
    case "$scenario" in
        linked-login-directory)
            install -d "$fixture_root/usr/local/share"
            ln -s "$outside" "$fixture_root/usr/local/share/wayland-sessions"
            ;;
        unexpected-local-redirect)
            rm -- "$fixture_root/usr/local"
            ln -s ../outside "$fixture_root/usr/local"
            ;;
        linked-atomic-destination)
            rmdir -- "$fixture_root/var/usrlocal"
            ln -s ../outside "$fixture_root/var/usrlocal"
            ;;
    esac
    outside_before="$(find "$outside" -type f -exec sha256sum {} + | sort)"
    for operation in install uninstall; do
        if [[ "$operation" == install ]]; then
            options=(--login-session)
        else
            options=(--uninstall --yes)
        fi
        if (main "${options[@]}") > "$fixture_root/$operation.log" 2>&1; then
            fail "$operation accepted unsafe system directory: $scenario"
        fi
        contains "$fixture_root/$operation.log" 'Refusing symbolic link in target directory path:'
        [[ ! -e "$XDG_CONFIG_HOME/sway-noir" ]] || fail "$scenario changed profile files"
        [[ "$(find "$outside" -type f -exec sha256sum {} + | sort)" == "$outside_before" ]] ||
            fail "$operation changed redirected system files: $scenario"
    done
done

# A read-only old entry is reported, never removed by migration/uninstall.
prepare_fixture readonly-legacy
readonly_usr=true
install -m 644 "$repo_root/session/sway-noir.desktop" "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop"
(main --login-session) > "$fixture_root/install.log" 2>&1
contains "$fixture_root/install.log" 'Retaining read-only old session entry'
(main --uninstall --yes) > "$fixture_root/uninstall.log" 2>&1
contains "$fixture_root/uninstall.log" 'Preserving read-only system file'
[[ -f "$fixture_root/usr/share/wayland-sessions/sway-noir.desktop" ]] || fail 'removed read-only entry'

# GDM uses the daemon environment, not the invoking shell's XDG_DATA_DIRS.
prepare_fixture gdm-login
fixture_manager=gdm
export XDG_DATA_DIRS=/unrelated/user/share
printf 'OTHER=value\0XDG_DATA_DIRS=%s/usr/local/share:%s/usr/share\0' "$fixture_root" "$fixture_root" > "$fixture_root/proc/123/environ"
(main --login-session) > "$fixture_root/install.log" 2>&1
contains "$fixture_root/install.log" 'Verified gdm.service'
[[ -f "$fixture_root/usr/local/share/wayland-sessions/sway-noir.desktop" ]] || fail 'GDM environment ignored'
prepare_fixture gdm-custom-dirs
fixture_manager=gdm
printf 'XDG_DATA_DIRS=/unsupported/daemon/share\0' > "$fixture_root/proc/123/environ"
if (main --login-session) > "$fixture_root/install.log" 2>&1; then fail 'GDM unsupported search path accepted'; fi
[[ ! -e "$XDG_CONFIG_HOME/sway-noir" ]] || fail 'GDM failure changed profile'
prepare_fixture gdm-no-environment
fixture_manager=gdm
if (main --login-session) > "$fixture_root/install.log" 2>&1; then fail 'unreadable GDM environment accepted'; fi
[[ ! -e "$XDG_CONFIG_HOME/sway-noir" ]] || fail 'unreadable GDM environment changed files'

printf 'PASS: dependency hints/probes and sandboxed login install, update, migration, conflicts, read-only handling and uninstall (SDDM/GDM)\n'
