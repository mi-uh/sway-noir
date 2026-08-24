# Sway Noir

A warm, low-glare Sway setup with charcoal surfaces, muted burgundy accents,
Vim-style navigation, and matching Waybar, Fuzzel, Mako, swaylock, and
wallpaper artwork.

Sway Noir is a standalone profile. It does not replace an existing Sway or
application configuration.

## Requirements

The default terminal is foot and can be changed in the local override. The
optional packages enable night mode, media and brightness keys, and screenshots.

### Fedora 44

Core:

    sudo dnf install sway swaybg swaylock waybar fuzzel mako foot \
        ibm-plex-sans-fonts wireplumber

Optional:

    sudo dnf install gammastep playerctl brightnessctl grim pulseaudio-utils

### Debian 13 (Trixie)

Core:

    sudo apt install sway swaybg swaylock waybar fuzzel mako-notifier foot \
        fonts-ibm-plex wireplumber

Optional:

    sudo apt install gammastep playerctl brightnessctl grim pulseaudio-utils

The `fonts-ibm-plex` package is in Debian's `contrib` component, which must be
enabled in the APT sources.

### Arch Linux

Core:

    sudo pacman -S sway swaybg swaylock waybar fuzzel mako foot \
        ttf-ibm-plex wireplumber

Optional:

    sudo pacman -S gammastep playerctl brightnessctl grim libpulse

Waybar includes a battery indicator for notebooks; it stays hidden when no
battery is available. Gammastep support is included as an optional night mode.

The configuration is hardware-neutral and uses Sway's automatic output
detection. It is developed and tested on Fedora 44 with Sway 1.11; other Linux
distributions may require different session setup.

## Install

    ./install.sh

This installs the profile below:

    ${XDG_CONFIG_HOME:-$HOME/.config}/sway-noir

Existing files at that destination are backed up below
~/.config/sway-setup-backups. The installer never modifies ~/.config/sway or
other application configuration directories. Sway Noir provides manual locking,
but deliberately does not configure automatic locking or suspend.

Start it from a TTY:

    ~/.config/sway-noir/start-sway-noir

To add a Sway Noir entry to a display manager such as GDM:

    sudo install -Dm755 start-sway-noir /usr/local/bin/start-sway-noir
    sudo install -Dm644 session/sway-noir.desktop \
        /usr/share/wayland-sessions/sway-noir.desktop

The system-wide session entry is optional. Remove those two installed files to
remove it again.

## Personal configuration

The installer creates sway/config.d/99-local.conf once and never overwrites it.
Use it for a different terminal, keyboard layout, monitor placement, scaling,
or workspace-to-output assignments. Commented examples are included.

Waybar uses one generic configuration on every connected output. Users who
want different bars per output can replace waybar/config.jsonc in their local
profile.

To enable the optional night mode, install Gammastep and uncomment its line in
sway/config.d/91-autostart.conf. It uses fixed local times by default: 6100 K
from 07:00 and 5600 K from 20:00, without location access. The configuration
also includes commented GeoClue and manual-location alternatives.

## Keys

- Super+h/j/k/l: focus
- Super+Shift+h/j/k/l: move windows
- Super+b / Super+v: horizontal / vertical split
- Super+r, then h/j/k/l: resize mode
- Super+1..0: workspaces
- Super+p / Super+n: previous / next workspace on the current output
- Super+d: Fuzzel
- Super+Enter: terminal
- Super+Shift+x: lock
- Super+Shift+q: close
- Super+Shift+e: exit Sway

## License

Sway Noir is released under the MIT License. The wallpaper and lock-screen
artwork were generated with ChatGPT.
