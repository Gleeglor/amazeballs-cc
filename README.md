# Amazeballs ComputerCraft scripts

Public script repo for the Amazeballs Minecraft pack. Computers on multiplayer pull selected files from here over HTTP on every reboot.

Repo: [gleeglor/amazeballs-cc](https://github.com/gleeglor/amazeballs-cc)

## Install on a computer (once)

In the ComputerCraft computer shell:

```text
wget https://raw.githubusercontent.com/gleeglor/amazeballs-cc/main/install.lua install
install
```

That downloads `updater.lua`, writes a managed `startup.lua`, and starts first-time setup.

### Setup UI

If `/cc_update.json` is missing, the updater shows the catalog folder tree (`cannon/`, `navigation/`, …):

| Key | Action |
|-----|--------|
| Up / Down | Move cursor |
| Space | Toggle select file |
| Enter | Open folder, toggle file, or finish on **Done** |
| Backspace | Go up one folder |

After you choose **Done**, pick which downloaded program to run on boot (or `0` for none). Selection is saved to `/cc_update.json`.

### Every reboot

`startup.lua` runs the updater (which re-downloads your selected files, and self-updates `updater.lua`), then runs the configured boot program (for example `autorun`).

### Reset setup

Delete the config and run setup again:

```text
delete cc_update.json
updater --setup
```

Or reboot after deleting `cc_update.json` (startup will run the updater into setup).

## Roles (cannon)

Typical selections:

| Computer | Select | Boot program |
|----------|--------|--------------|
| Hub | `cannon/hub.lua` + `cannon/startup_hub.lua` | `autorun` |
| Fire | `cannon/fire.lua` + `cannon/startup_fire.lua` | `autorun` |
| Ammo turtle | `cannon/ammo.lua` + `cannon/startup_ammo.lua` | `autorun` |

Role startups install as **`autorun.lua`**, never as `startup.lua`, so they cannot overwrite the updater boot chain.

## Keep scripts up to date (author)

Local source of truth (this Cursor workspace):

`cc-scripts/` inside the Amazeballs Minecraft instance folder.

1. Edit Lua files under `cc-scripts/` (and update `catalog.json` when adding folders/files).
2. Commit and push to `gleeglor/amazeballs-cc` (`main`).
3. In-game: reboot the computer, or run `updater`.

No extra sync daemon — reboot (or `updater`) pulls the latest selected files from GitHub.

## Server requirement

The **multiplayer server** must allow ComputerCraft HTTP to `raw.githubusercontent.com`. If installs or pulls fail, ask an admin to enable the CC HTTP API and allow that host.

## Layout

```text
catalog.json     # tree shown in setup
install.lua      # wget bootstrap
updater.lua      # setup + pull + self-update
cannon/          # hub, fire, ammo scripts
navigation/      # placeholder for future scripts
```
