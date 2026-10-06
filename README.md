# Gears of War: E-Day – Offline Campaign

Play the single-player campaign of **Gears of War: E-Day** without an internet
connection: **CONTINUE**, **NEW** (from the very beginning, with a difficulty
choice) and **LOAD** (any save slot and checkpoint).

You need your own copy of the game on Steam. Steam still checks that you own the
game (in Steam Offline Mode). No game files are modified and nothing is cracked –
the mod adds a small script loader ([UE4SS](https://github.com/UE4SS-RE/RE-UE4SS))
that is active only when you start the game with the offline shortcut.

> Unofficial fan-made mod, not affiliated with or endorsed by The Coalition,
> Xbox Game Studios or Microsoft. Use it only with your own, legally owned copy
> of the game. Use at your own risk.

## Download

Get the ZIP from the [Releases](../../releases) page (or use *Code → Download ZIP*).

## Requirements

- Gears of War: E-Day bought on your Steam account and installed.
- Game version: **Steam build 25708270 (CL-4894450)**. After a game update the mod
  may stop working – the installer warns you if your version differs.
- Steam Offline Mode must work: sign in online once with *Remember my password*,
  then *Steam → Go Offline…*.
- Game language: **English** (the mod finds the menu entries by their English
  names CONTINUE / NEW / LOAD / LOBBY BROWSER).
- Windows 10/11 (the installer uses the built-in PowerShell).

## Install

1. If Windows marks the downloaded ZIP as blocked: right-click the ZIP →
   *Properties* → tick *Unblock* → *OK*. Then extract it anywhere.
2. Run `INSTALL.cmd`. It
   - finds the game in your Steam libraries,
   - backs up your saves to `<game folder>\_offline_campaign\`,
   - installs the mod and creates the desktop shortcut
     **Gears of War E-Day (offline)**.

If the game is not found, run it from a command prompt with the path:

```bat
INSTALL.cmd -GamePath "D:\SteamLibrary\steamapps\common\GoWEDay"
```

## Playing

1. Put Steam in Offline Mode.
2. Start the game with the desktop shortcut **Gears of War E-Day (offline)**
   (or `Play-offline.cmd` in the game folder).
3. An *Easy Anti-Cheat … Unable to load* window may appear – click **OK**.
   Anti-cheat is only needed for online modes, which are off in this session.
4. Title screen: press **Enter**. The mod closes the endless
   *Waiting for Platform Sign In* after a few seconds.
5. Choose **CAMPAIGN**, then:

| Entry | What it does |
|---|---|
| **CONTINUE** | Loads the last checkpoint of the campaign you played last. |
| **NEW** | Starts a new campaign from the very beginning (intro and cutscenes, like a new player). |
| **LOAD** | Lets you pick a save slot and a checkpoint. |
| **LOBBY BROWSER** | Online only – shows `ONLINE ONLY`. |

**NEW** turns the menu into:

```
‹ DIFFICULTY: NORMAL ›   Enter cycles CASUAL / NORMAL / HARDCORE / INSANE / INCONCEIVABLE
‹ SLOT 2: EMPTY ›        Enter cycles the save slot (1-5). Empty slots come first.
                         A used slot shows OVERWRITE - starting there DELETES that campaign's save.
START NEW CAMPAIGN
BACK
```

**LOAD** turns the menu into:

```
‹ SLOT 1 · HARDCORE ›                          Enter cycles the campaigns (slots)
‹ 1.2 EMERGENCE · 2026-10-06 19:08 (1/4) ›     Enter cycles the checkpoints; 1 = newest
LOAD CHECKPOINT
BACK
```

Controls in these menus: **Up/Down** (or hovering with the mouse) move the
highlight, **Enter** selects or changes a value, **Backspace** goes back to the
main menu. Use the keyboard – mouse clicks don't select here, and Left/Right do
nothing.

Checkpoints are saved locally in the normal save files, so the same progress is
there when you play online again.

**Difficulty:** offline the game would use a default difficulty instead of the one
stored in your save. The mod applies the save slot's difficulty after every load,
and NEW stores the difficulty you picked.

A normal launch from Steam is not affected – the mod is only active for sessions
started with the offline shortcut. Use the normal Steam launch for online play.

## Uninstall

Run `UNINSTALL.cmd`. It removes everything the installer added (mod files,
`Play-offline.cmd`, desktop shortcut). Your save backups stay in
`<game folder>\_offline_campaign\` – delete that folder if you don't need them.
Your actual saves (`%LOCALAPPDATA%\Microsoft\Gears of War E-Day\Saves`) are never
touched by the uninstaller.

## What works / what doesn't

**Works offline:** CONTINUE, NEW (difficulty and slot choice), LOAD (any slot, any
checkpoint), checkpoint saving and reloading.

**Not available offline:** Lobby Browser, Practice, Store, co-op, multiplayer, Horde.

If the campaign you played last has no checkpoint yet (for example you quit during
the intro of a new campaign), the game itself hides CONTINUE – use LOAD instead.

Not tested offline yet: transitions between acts and the ending/credits.

## Troubleshooting

- **The menu disappears after choosing NEW/LOAD, or *Waiting for Platform Sign In*
  never goes away:** the game was not started with the offline shortcut, or the
  game was updated and the mod no longer matches it.
- **Log file:** `<game folder>\FairlightConcept\Binaries\Win64\ue4ss\UE4SS.log`
  (lines starting with `[OfflineCampaign]`).
- **After a game update:** run `UNINSTALL.cmd` and play online until an updated
  version of the mod is available.

## How it works

The Lua mod (`files/ue4ss/Mods/OfflineCampaign/Scripts/main.lua`) runs only when
the launcher sets `GOWEDAY_OFFLINE=1`. It:

- reports the local campaign data as in sync and finishes the platform sign-in
  that never completes offline,
- starts the campaign map directly (`LoadLastCheckpoint=<slot>` for
  CONTINUE/LOAD, `mission=<first mission>` for NEW) instead of going through the
  online lobby,
- intercepts NEW / LOAD / LOBBY BROWSER, whose original screens need the online
  services, and reuses the campaign menu entries as a small picker,
- applies the difficulty stored in the active save slot after each load.

`Play-offline.cmd` copies the UE4SS loader (`ue4ss\dwmapi.dll.offline`) next to the
game only for the offline session and removes it when the game exits.

## Contents and license

| Path | |
|---|---|
| `files/ue4ss/` | UE4SS (MIT license, see `files/ue4ss/LICENSE.txt`), configured for GoW E-Day (Unreal Engine 5.6) |
| `files/ue4ss/Mods/OfflineCampaign/Scripts/main.lua` | the mod |
| `files/installer.ps1` | installer / uninstaller (`INSTALL.cmd`, `UNINSTALL.cmd`) |
| `files/Play-offline.cmd` | offline launcher (copied to the game folder) |
| `files/dwmapi.dll` | UE4SS loader (stored as `ue4ss\dwmapi.dll.offline`) |
