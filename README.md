# Amazeballs ComputerCraft scripts

Public script repo for the Amazeballs Minecraft pack. Computers on multiplayer pull selected files from here over HTTP on every reboot.

Repo: [gleeglor/amazeballs-cc](https://github.com/Gleeglor/amazeballs-cc)

## Install on a computer

In the ComputerCraft computer shell:

```text
wget https://raw.githubusercontent.com/gleeglor/amazeballs-cc/main/install.lua install
install
```

That downloads `updater.lua`, writes a managed `startup.lua`, and opens file selection setup.

### Reinstall / change selected files

Run install again (or force setup on the updater). Previous selections are pre-checked so you can tweak them:

```text
install
```

Or without re-downloading install.lua:

```text
updater --setup
```

Aliases: `updater setup`, `updater reinstall`.

Refresh updater files and pull only (no selection UI):

```text
install pull
```

### Setup UI

| Key | Action |
|-----|--------|
| Up / Down | Move cursor |
| Space | Toggle select file |
| Enter | Open folder, toggle file, or finish on **[Done] save selection** |
| Backspace | Go up one folder |

After **Done**, pick which downloaded program to run on boot (or `0` for none). Selection is saved to `/cc_update.json`. Empty selection cancels and keeps the previous config.

### Every reboot

`startup.lua` runs the updater (re-downloads your selected files and self-updates `updater.lua`), then runs the configured boot program (for example `autorun`).

## Roles (cannon)

The `cannon/` folder lists **3 scripts** (one per computer role). Pick the script for that machine, then choose it as the boot program:

| Computer | Select | Boot program |
|----------|--------|--------------|
| Hub | `hub.lua` | `hub` |
| Fire | `fire.lua` | `fire` |
| Ammo turtle | `ammo.lua` | `ammo` |

`startup.lua` is owned by the installer (updater chain). Your role program is started via the boot choice in setup (`run` in `/cc_update.json`), not by separate autorun helper files.

## Keep scripts up to date (author)

Local source of truth (this Cursor workspace):

`cc-scripts/` inside the Amazeballs Minecraft instance folder.

1. Edit Lua files under `cc-scripts/` (and update `catalog.json` when adding folders/files).
2. Commit and push to `gleeglor/amazeballs-cc` (`main`).
3. In-game: reboot the computer, or run `updater`.

No extra sync daemon. Reboot (or `updater`) pulls the latest selected files from GitHub.

## Server requirement

The **multiplayer server** must allow ComputerCraft HTTP to `raw.githubusercontent.com`. If installs or pulls fail, ask an admin to enable the CC HTTP API and allow that host.

## Layout

```text
catalog.json / catalog.v2.json
install.lua / updater.lua
cannon/
```
