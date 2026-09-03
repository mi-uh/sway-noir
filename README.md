# Sway Noir

Sway Noir is a standalone Sway profile with a warm dark appearance,
Vim-style navigation, and a deliberately lean desktop setup.

![Sway Noir with Waybar and Fuzzel](sway-noir-screenshot.webp)

## What does Sway Noir provide?

- A matching theme for Waybar, Fuzzel, Mako, swaylock, and the wallpaper
- Vim-style window, focus, and workspace controls
- Automatic output detection without a hard-coded hardware layout
- Night color through Gammastep
- Optional login-screen integration and application dark mode

## Installation

Install the required packages:

Fedora:
```bash
sudo dnf install sway swaybg swayidle swaylock waybar fuzzel mako foot gammastep \
    ibm-plex-sans-fonts playerctl brightnessctl grim pulseaudio-utils \
    pavucontrol dconf gsettings-desktop-schemas pipewire wireplumber \
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr
```

Debian and Ubuntu:
```bash
sudo apt install sway swaybg swayidle swaylock waybar fuzzel mako-notifier foot \
    gammastep fonts-ibm-plex playerctl brightnessctl grim pulseaudio-utils \
    pavucontrol dconf-cli gsettings-desktop-schemas pipewire wireplumber \
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

Install only the user profile without prompts or optional system changes:

```bash
./install.sh --profile-only
```

Only the login-screen entry requires `sudo`. Existing unrelated files are not
overwritten. Replaced Sway Noir files are backed up below
`~/.config/sway-setup-backups`.

The installer validates its required commands and the profile's runtime
commands before changing files. If dependencies are missing, it exits with the
Fedora package command needed to install them. It should work on Debian- or
Arch-based systems as well, but so far it has been tested only on Fedora 44.

GNOME and Plasma are not required. They can remain installed alongside Sway
Noir. It also works on a Sway-only system.

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
- `Super+n/p`: switch to the next/previous workspace
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
- Sway Noir starts or restarts the desktop portal only after the graphical
  session is ready, as required by xdg-desktop-portal 1.21 and newer.
- Distributions other than Fedora may work but are currently untested.

## License

MIT
