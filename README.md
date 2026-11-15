# Sway Noir

A standalone Sway profile with matching desktop themes and Vim-style navigation.

## Screenshots

**Praxis**

![Praxis desktop with gold accents, bottom status bar and theme menu](screenshots/praxis.webp)

**Rain (default)**

![Rain desktop with burgundy accents, floating top bar and theme menu](screenshots/rain.webp)

**Retro**

![Retro desktop with green monospace text, bottom status bar and theme menu](screenshots/retro.webp)

## Install

Tested on Fedora 44 and Fedora 45 Atomic.
Other distributions are currently untested.

Run the following steps as a **non-root user**.

### 1. Download Sway Noir

```bash
git clone https://github.com/mi-uh/sway-noir.git
cd sway-noir
```

### 2. Check required software

```bash
./install.sh --check-deps
```

The check reports missing software and prints suggested installation commands.
It does not install anything. Install the missing **required packages**, then
run the check again. **Optional packages** add [extra features](#optional-features)
and can be skipped.

**Fedora Atomic:** Reboot after installing packages before repeating the check.

Once the check passes, continue with installation.

### 3. Install Sway Noir

```bash
./install.sh
```

The installer asks whether to add Sway Noir to your login screen and enable
dark mode for applications in your user account. You can also choose directly:

| Command | Purpose |
| --- | --- |
| `./install.sh --profile-only` | Install without optional changes or prompts |
| `./install.sh --login-session` | Install profile and login-screen entry for GDM or SDDM; requires `sudo` |
| `./install.sh --set-dark-mode` | Install profile and enable dark mode for applications in your user account |
| `./install.sh --list-deps` | List required and optional software |
| `./install.sh --check-deps --set-dark-mode` | Check required software, including dark-mode support; no changes |

Automatic login-screen integration supports GDM and SDDM only. For other login
managers, use `--profile-only` and add the session entry manually.

### File safety

Files replaced during installation or updates are backed up in
`~/.config/sway-setup-backups`.

## Start and control the desktop

Select **Sway Noir** on your login screen, or start it from a text console:

```bash
~/.config/sway-noir/start-sway-noir
```

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Super+Enter` / `Super+d` | Terminal / launcher |
| `Super+h/j/k/l` | Focus window |
| `Super+Shift+h/j/k/l` | Move window |
| `Super+r` | Resize mode |
| `Super+1..0` | Workspace |
| `Super+n` / `Super+p` | Next / previous workspace |
| `Super+Shift+t` | Theme menu; Escape cancels |
| `Super+Shift+x` / `Super+Shift+e` | Lock / exit |
| `Print` / `Shift+Print` | Region / full screenshot |

### Switch themes

Press **Super+Shift+t** and select a theme. Your applications stay open.
If switching fails, an error is shown and the previous theme is kept.

The same menu has a **Waybar position** entry:

- **Theme default:** Rain places the bar at the top; Praxis and Retro at the bottom.
- **Always top** / **Always bottom:** keep the bar at that edge, regardless of theme.

The selected option is marked in the position submenu. Escape cancels without
changing anything. Your choice survives theme changes and logging out/in.
Vertical margins follow the bar when its position changes.

Inside Sway Noir, you can also use these terminal commands:

```bash
# List available themes
~/.config/sway-noir/session/theme list
# Show the selected theme
~/.config/sway-noir/session/theme current
# Switch to Praxis
~/.config/sway-noir/session/theme set praxis
# Show the saved Waybar preference (default, top or bottom)
~/.config/sway-noir/session/theme bar-position
# Always place Waybar at the top
~/.config/sway-noir/session/theme bar-position top
# Restore each theme's default position
~/.config/sway-noir/session/theme bar-position default
```

Replace `praxis` with `rain`, `retro` or the name of your own theme.
Use `bar-position bottom` to pin the bar to the bottom. Add `--no-reload` to
`set ID` or `bar-position VALUE` to save a choice outside Sway Noir for the next login.

## Customize

### Personal settings

Change keyboard shortcuts, monitor settings and startup programs in
`~/.config/sway-noir/sway/config.d/99-local.conf`. This file is kept during
updates. See [99-local.conf.example](sway/config.d/99-local.conf.example) for examples.

Press **Super+Shift+c** to apply keyboard and monitor changes. After changing
startup programs or the audio-settings command, log out and back in.

### Optional features

| Feature | Required software |
| --- | --- |
| Volume keys | `wpctl` with PipeWire and WirePlumber |
| Audio settings | `pavucontrol` – opens when you click the volume display |
| Screenshots | `grim`; region selection also needs `slurp`; Escape cancels |
| Night color | `gammastep` |
| Authentication prompts | `lxqt-policykit-agent` and Qt Wayland |

Screenshots are saved to `~/Pictures/Screenshots` by default.

### Personal Waybar settings

Keep overrides in `~/.config/sway-noir/waybar/local.jsonc`, **not** in the managed
`base.jsonc`. Create it once after updating:

```bash
cd ~/.config/sway-noir/waybar
cp -n local.jsonc.example local.jsonc
```

Edit only the settings you want to change. Local values win over theme and base
settings; missing values still receive updates. Objects merge recursively, but
`modules-left`, `modules-center` and `modules-right` replace the entire list.
Updates and uninstall leave `local.jsonc` untouched.
Transfer existing personal edits from `base.jsonc` yourself; they are not migrated
automatically.

New right-hand status modules receive the theme's padding, colors and borders.
Both hardware modules also have matching text formats in all bundled themes.
Leave `format`, `align` and `justify` unset locally to inherit them.

#### Optional CPU and NVIDIA GPU temperatures

**Off by default:** the standard bar keeps native `cpu` utilization only and does
not enable GPU readings. To show **CPU 12 · 54** and **GPU 28 · 61**, without
units, add this list to `local.jsonc` (or uncomment it in the
[example](waybar/local.jsonc.example)):

```jsonc
"modules-right": ["pulseaudio", "network", "battery", "custom/cpu", "custom/gpu", "memory", "tray", "clock"]
```

CPU temperatures use Intel/AMD kernel sensors, with CPU thermal zones as a
fallback. Missing temperatures leave utilization visible. NVIDIA GPU readings
require the driver's `nvidia-smi`; unavailable GPUs are hidden. No sensor packages
are required. Remove an old local GPU `exec` to use the built-in combined reading.
For another GPU, override `exec` with
`"\"$SWAY_NOIR_DIR/session/hardware-status\" gpu 1"`.

To disable temperatures again, replace `custom/cpu` with `cpu` and remove
`custom/gpu`, or remove the local module list to restore all defaults.

Inside Sway Noir, reselect the current theme with **Super+Shift+t** to apply
changes, or log out and back in. Do not edit generated files under
`~/.local/state/sway-noir/current/`.

### Personal themes

To create a color variation of Rain, create the folder
`~/.config/sway-noir/themes/my-theme/` and add a file named `theme.conf`:

```ini
name=My Theme
accent=#7496b8
accent_surface=#1d2936
```

Choose your own name and colors, then select **My Theme** from the theme menu.
Other settings use Rain's defaults. For more color and layout settings, see
[themes/rain/theme.conf](themes/rain/theme.conf).

Set `bar_position=top` or `bar_position=bottom` in your theme's `theme.conf`
to choose its default edge. `bar_margin_top` and `bar_margin_bottom` accept
pixel values from 0 to 99 and swap when a fixed preference moves the bar.

#### Waybar: shared behavior, theme-specific appearance

[`waybar/base.jsonc`](waybar/base.jsonc) defines module order, actions, intervals,
workspace behavior, the clock and the position preference. The default
[`waybar/config.jsonc`](waybar/config.jsonc) contains Rain's appearance overrides;
Praxis and Retro provide their own small overrides in `themes/ID/waybar/config.jsonc`.
Colors and widget styling remain in `theme.conf` and `waybar/style.css`.

Waybar's native `include` merges objects recursively: settings in the theme file
win, and the shared base supplies missing settings. Arrays are replaced, not
concatenated. The quoted environment-variable reference keeps paths with spaces
safe and points to the generated base for the current selection:

```jsonc
{
  "include": "\"${SWAY_NOIR_THEME_DIR}/waybar/base.jsonc\"",
  "height": 32,
  "cpu": {"format": "CPU {usage}"}
}
```

A personal theme without its own Waybar config still inherits Rain's appearance.
Existing complete personal configs without `include` remain complete replacements.
In those files, use these placeholders to respect the position preference:

```jsonc
"position": "{{bar_position}}",
"margin-top": {{bar_margin_top}},
"margin-bottom": {{bar_margin_bottom}},
```

## Update

Open a terminal in the cloned `sway-noir` repository and run:

```bash
git pull --ff-only
./install.sh
```

If you use the Sway Noir login-screen entry, select that option again when
prompted. **Log out and back in after updating.**

## Uninstall

From the cloned repository, run:

```bash
./install.sh --uninstall
```

Removes unchanged files installed by Sway Noir. Personal settings, modified
files, personal themes and backups are kept. Software packages and application
dark-mode settings are not changed.

## Testing code changes

If you modify Sway Noir's scripts or configuration, run the automated tests
from the repository directory:

```bash
bash tests/run.sh
```

See [tests/README.md](tests/README.md) for test requirements and manual checks.

## License

[MIT](LICENSE)

Bundled wallpapers and lock-screen images were generated with ChatGPT (OpenAI).
See [image provenance and reuse](ASSETS.md).
