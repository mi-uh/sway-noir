# Sway Noir

Sway Noir is a standalone Sway profile for Fedora with a warm dark appearance,
Vim-style navigation, and a deliberately lean desktop setup. It does not
replace an existing Sway configuration and is installed separately below
`~/.config/sway-noir`.

![Sway Noir with Waybar and Fuzzel](sway-noir-screenshot.webp)

## What does Sway Noir provide?

- A matching theme for Waybar, Fuzzel, Mako, swaylock, and the wallpaper
- Vim-style window, focus, and workspace controls
- Automatic output detection without a hard-coded hardware layout
- Night color through Gammastep and manual locking without automatic suspend
- GTK/WLR portals for file dialogs, screenshots, and screen sharing
- Optional login-screen integration and application dark mode

Sway Noir is intended for users who prefer a focused Wayland desktop and want
to keep personal monitor, input, and key-binding changes in a single local
configuration file. It is developed and tested on Fedora 44 with Sway 1.11.

## Installation

Install the required Fedora packages:

```bash
sudo dnf install sway swaybg swaylock waybar fuzzel mako foot gammastep \
    ibm-plex-sans-fonts playerctl brightnessctl grim pulseaudio-utils \
    dconf gsettings-desktop-schemas pipewire wireplumber \
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr
```

Clone the repository and run the installer:

```bash
git clone https://github.com/mi-uh/sway-noir.git
cd sway-noir
./install.sh
```

The installer asks whether to:

1. install the Sway Noir profile,
2. add an optional login-screen entry,
3. enable the optional user-wide dark mode.

Before changing anything, it displays every affected file and directory with
its full destination path.

Answer yes to every question automatically:

```bash
./install.sh -y
```

Only the login-screen entry requires `sudo`. Existing unrelated files are not
overwritten. Replaced Sway Noir files are backed up below
`~/.config/sway-setup-backups`.

GNOME and Plasma are not required. They can remain installed alongside Sway
Noir, which also works on a Sway-only system.

## Usage

Select Sway Noir on the login screen or start it from a TTY:

```bash
~/.config/sway-noir/start-sway-noir
```

Important key bindings:

- `Super+Enter`: open the terminal
- `Super+d`: open Fuzzel
- `Super+h/j/k/l`: change focus
- `Super+Shift+h/j/k/l`: move windows
- `Super+r`: enter resize mode
- `Super+1..0`: switch workspaces
- `Super+Shift+x`: lock the screen
- `Super+Shift+e`: exit Sway

Keep personal settings in:

```text
~/.config/sway-noir/sway/config.d/99-local.conf
```

The installer never overwrites this file during installation or updates.

## Updating

```bash
git pull
./install.sh
```

The installer displays the plan again and backs up files it replaces.

## Uninstalling

```bash
./install.sh --uninstall
```

Uninstall without confirmation:

```bash
./install.sh --uninstall -y
```

The uninstaller preserves:

- all backups,
- `99-local.conf`,
- user-wide dark-mode settings,
- unknown files not managed by Sway Noir.

## Notes

- Dark mode is not guaranteed to be honored by every application.
- Simultaneous graphical sessions for the same Unix user are not supported.
- Other distributions may work but are currently untested.

## License

MIT. The wallpaper and lock-screen artwork were generated with ChatGPT.
