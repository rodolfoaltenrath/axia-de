# Axia-DE

Axia-DE is a desktop environment and Wayland compositor built from scratch with Zig and `wlroots`.

Current focus:
- low-level Wayland compositor core
- modular architecture by feature/domain
- lightweight desktop UX primitives before visual polish

## Current Status

Already implemented:
- compositor core with `wl_display`, backend, renderer and allocator
- output management and scene graph rendering
- keyboard and pointer input
- XDG toplevel windows
- layer-shell support
- top panel client with:
  - `Areas de Trabalho`
  - `Aplicativos`
  - centered clock
  - calendar popup
- workspaces with:
  - `Super+1..4` to switch
  - `Super+Shift+1..4` to move the focused window
  - `Super+Tab` to cycle
  - workspace popup integrated with the panel
- compositor-driven move/resize with:
  - `Super + left mouse` to move
  - `Super + right mouse` to resize
- launcher popup with defaults for:
  - `cosmic-terminal` with fallback to `alacritty`
  - `cosmic-files` with fallback to `xdg-open "$HOME"`
  - `firefox`

## Repository Layout

```text
src/core/      compositor bootstrap, outputs, protocol globals
src/input/     keyboard and pointer handling
src/shell/     xdg-shell, views, workspaces, decorations
src/layers/    layer-shell integration
src/render/    scene/background helpers
src/panel/     top panel Wayland client
src/ipc/       compositor/panel IPC
protocols/     vendored protocol XML files
docs/          roadmap and project notes
```

## Requirements

Recommended target environment:
- CachyOS / Arch Linux
- Zig 0.15.x
- `wlroots 0.18`

Packages typically required on Arch/CachyOS:

```bash
sudo pacman -S --needed zig base-devel pkgconf wlroots0.18 wayland wayland-protocols libxkbcommon pixman mesa libinput seatd cairo cosmic-files cosmic-terminal alacritty firefox
```

## Build

```bash
zig build
```

## Run

Nested inside your current Wayland session:

```bash
zig build run
```

This starts:
- `axia-de`
- `axia-panel`

## Interaction

Keyboard:
- `Escape`: terminate Axia-DE
- `Super+1..4`: switch workspaces
- `Super+Shift+1..4`: move focused window to a workspace
- `Super+Tab`: cycle workspaces

Mouse:
- `Super + left mouse`: move focused window
- `Super + right mouse`: resize focused window

Panel:
- `Areas de Trabalho`: workspace popup
- `Aplicativos`: app launcher popup
- clock: calendar popup

Wallpaper:
- default asset: `assets/wallpapers/axia-aurora.png`
- override per run:

```bash
AXIA_WALLPAPER=/caminho/para/seu-wallpaper.png zig build run
```

## Notes

- The panel is a separate Wayland client spawned by the compositor.
- The project is still in active prototyping, so some UX details are intentionally minimal.
- Generated build output is ignored via `.gitignore`.

## Roadmap

See [docs/roadmap.md](docs/roadmap.md).
