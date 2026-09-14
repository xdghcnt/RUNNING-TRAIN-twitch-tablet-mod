# RUNNING TRAIN — Twitch Tablet

A physical tablet in the driver's cab of **RUNNING TRAIN / 走ル列車！**
(Steam AppID 4630570) that shows your Twitch chat on its screen.

The tablet is an object in the cab, not an overlay: it sits where you put it,
rides with the train, and you glance at it the way you would at a phone clipped
to the desk. Works well with head tracking.

---

## What it does

- Live Twitch chat on an in-cab screen: user names in their Twitch colours,
  Twitch emotes as pictures (the channel's own ones included), word wrap,
  newest message at the bottom.
- Reads chat anonymously. No login, no token, nothing to authorise.
- Ready-made tablet positions for **hr1500, hr1100, kr5000 and DC8500**. In any
  other train the tablet appears right in front of you, and you place it once.
- Reconnects by itself after network drops.

---

## Install

Extract the archive into the folder that holds the real game executable:

```
...\Steam\steamapps\common\RUNNING TRAIN\RunningTrain\Binaries\Win64\
```

You should end up with `dwmapi.dll` and a folder `ue4ss` sitting next to
`RunningTrain-Win64-Shipping.exe`.

**Already have the HeadTracking mod?** Extract this archive over it. Allow the
files to be overwritten; they are the same UE4SS files. Both mods keep working,
and the order you install them in does not matter.

## Set your channel

Start the game once and get into a cab. The tablet says *Set Channel in
TwitchTablet.ini*. Open

```
ue4ss\Mods\RunningTrainTwitchTablet\TwitchTablet.ini
```

and put your channel name in, as in `twitch.tv/<channel>`:

```ini
[Twitch]
Channel = yourchannel
```

Save the file. The mod picks the change up within a few seconds, with no
restart needed.

---

## Controls

All on the numpad by default. Every key can be changed in the config (see
[No numpad?](#no-numpad)).

| Key | Action |
|---|---|
| <kbd>Num1</kbd> | Hide / show the tablet |
| <kbd>Num2</kbd> | Screen off / on. The tablet stays, the screen goes dark |
| <kbd>Num4</kbd> / <kbd>Num6</kbd> | Chat font smaller / bigger |
| <kbd>Num7</kbd> / <kbd>Num9</kbd> | Screen dimmer / brighter |
| <kbd>Num8</kbd> | Disconnect from / reconnect to Twitch |
| <kbd>Num0</kbd> | Calibration mode on / off (placing the tablet, see below) |
| <kbd>Num5</kbd> | Write the connection status and a 10 s frame-time sample to the log |
| <kbd>Num*</kbd> | Reload the mod and its config |

### Calibration: placing the tablet

Press <kbd>Num0</kbd>. A yellow band on the screen shows the mode, and the
numpad now moves the tablet:

| Key | MOVE | ROTATE | SIZE |
|---|---|---|---|
| <kbd>Num4</kbd> / <kbd>Num6</kbd> | left / right | turn left / right | narrower / wider |
| <kbd>Num8</kbd> / <kbd>Num2</kbd> | forward / back | tilt | taller / shorter |
| <kbd>Num9</kbd> / <kbd>Num3</kbd> | up / down | roll | — |

| Key | Action |
|---|---|
| <kbd>Num5</kbd> | Next mode: MOVE → ROTATE → SIZE |
| <kbd>Num+</kbd> / <kbd>Num-</kbd> | Scale the whole tablet |
| <kbd>Num/</kbd> | Put the tablet right in front of your eyes, then fine-tune it from there |
| <kbd>Enter</kbd> | **Save** for this train. The band flashes `SAVED` |
| <kbd>Num.</kbd> | Undo the changes since the last save |
| <kbd>Num7</kbd> | Fine steps (×0.1) on / off |
| hold <kbd>Alt</kbd> | Big steps (×10) |
| <kbd>Num0</kbd> | Leave calibration |

Steps are 1 cm and 1°. Keys repeat while held. The font size you set with
<kbd>Num4</kbd>/<kbd>Num6</kbd> is saved with the train too.

Each train keeps its own position. In a train with no saved position the tablet
appears in front of you with the hint *NEW TRAIN: Num0 calibrate, Enter save*.

Avoid <kbd>1</kbd>–<kbd>3</kbd> and the F-keys if you remap anything: the game
uses them.

---

## Configuration

Two files in `ue4ss\Mods\RunningTrainTwitchTablet\`:

| File | What it is |
|---|---|
| `TwitchTablet.default.ini` | Every option with its explanation, plus the train presets. **Updates replace it**, so do not edit it. |
| `TwitchTablet.ini` | **Your** settings. Anything here overrides the same key in the default file. Created on first start. Updates never touch it, and calibration saves go here. |

To change an option, copy its line (with its `[Section]` header) from the
default file into `TwitchTablet.ini` and edit it there.

| Section | Options |
|---|---|
| `[Twitch]` | `Channel`, and `Enabled` (`false` stops connecting at all) |
| `[Tablet]` | `AutoSpawn` (show the tablet on its own in the cab), plus the size and font of the tablet in a train you have not calibrated yet |
| `[Screen]` | `Brightness` at start (0.05–1.0, default 0.64), `MaxMessages` kept, `PixelsPerCm` (text sharpness), `Emotes` (`false` shows them as words) |
| `[Keys]` | One line per action, see below |
| `[Train.<car class>]` | Position, size and font for one train; written by calibration |

### No numpad?

`[Keys]` maps each action to an Unreal key name. For example, on a keyboard
without a numpad:

```ini
[Keys]
Tablet = Insert
Screen = Delete
Calibrate = Home
FontSmaller = PageDown
FontBigger = PageUp
CalLeft = Left
CalRight = Right
CalForward = Up
CalBack = Down
```

Key names: `A`…`Z`, `Zero`…`Nine` (top row), `F1`…`F12`, `Insert`, `Delete`,
`Home`, `End`, `PageUp`, `PageDown`, `Left`, `Right`, `Up`, `Down`,
`NumPadZero`…`NumPadNine`, `Add`, `Subtract`, `Multiply`, `Divide`, `Decimal`,
`Enter`. An empty value switches an action off. If two actions share a key, the
log says so.

The full list of actions, with the defaults, is in `TwitchTablet.default.ini`.
Two testing aids are there too, off by default: `FakeMessage` (a local
placeholder chat line) and `DropConnection` (drops the Twitch connection on
purpose, to watch it reconnect).

---

## Troubleshooting

The mod logs to `ue4ss\UE4SS.log`. Its lines start with `[Tablet]`.

**No tablet in the cab**
- Press <kbd>Num1</kbd>: it may be hidden.
- Wait a few seconds after the route loads. The tablet appears once the cab is
  ready.

**The tablet is somewhere odd, or outside the train**
That train has no preset. Press <kbd>Num0</kbd>, then <kbd>Num/</kbd> to bring
it in front of you, place it, and press <kbd>Enter</kbd>.

**The screen says "waiting for chat" and nothing comes**
- Check the channel name in `TwitchTablet.ini`.
- Press <kbd>Num5</kbd> and look for the `[Twitch]` status line in the log.
- Chat only shows messages sent after you joined. A quiet channel shows
  nothing until someone writes.

**Too bright / glowing at night**
Press <kbd>Num7</kbd> a few times, or set `Brightness` in `[Screen]`.

**Antivirus flags it**
UE4SS loads through a proxy DLL, a pattern that heuristic scanners dislike. The
mod connects only to Twitch: its chat server (`irc.chat.twitch.tv`, TLS,
read-only) and its emote image server (`static-cdn.jtvnw.net`, HTTPS).

---

## Uninstall

Delete `ue4ss\Mods\RunningTrainTwitchTablet` and
`ue4ss\Mods\RunningTrainTwitchTabletNative`. If no other UE4SS mod is left,
also delete `dwmapi.dll` and the `ue4ss` folder. The game's own files are never
modified.

---

## Known limitations

- The game is in **Early Access**. A patch can change the cabs and break the
  presets or the mod.
- Twitch's own emotes only. Animated ones show their first frame. Third-party
  sets (BTTV, FFZ, 7TV) and badges show as text or not at all.
- No scrolling back through older messages.
- <kbd>Enter</kbd> on the numpad and the main <kbd>Enter</kbd> are the same key
  to the game. Save only reacts while calibrating.

---

## How it works

- **The tablet** is an actor the mod spawns and attaches to the cab interior
  (`BaseUntendai`, or the car body on trains without a separate desk). That is
  why it moves with the train. The screen is a plane with an unlit material
  showing a render target.
- **The chat** is drawn into that render target with the engine's Canvas API,
  and redrawn only when something changed.
- **Twitch** is read by a small C++ UE4SS mod: anonymous IRC over TLS, with
  tags for names, colours and emote positions, on a background thread, with
  keepalive, reconnect and backoff. It hands messages to Lua through a queue,
  so the game never waits on the network. TLS is not only for privacy: some
  ISPs freeze plain IRC connections to Twitch after ~16 KB.
- **Emotes** are downloaded once by the C++ mod into `emotecache\`, imported
  by the engine, and packed into one atlas texture that the tablet owns; the
  chat draws them from there.
- **Trains** are told apart by the class of the car you drive. That is the
  `[Train.<car class>]` section name.

The engineering log, including the dead ends, is in
[`PROGRESS.md`](PROGRESS.md) and [`RESEARCH.md`](RESEARCH.md) (Russian).

---

## Building from source

You only need this to change the mod. The release archive is ready to use.

```powershell
scripts\Get-BuildDeps.ps1     # public RE-UE4SS headers + fmt
scripts\Build-CppMod.ps1      # the Twitch client (VS Build Tools, C++ workload)
scripts\Test-TwitchProbe.ps1  # the Twitch client against live chat, outside the game
scripts\Test-EmoteProbe.ps1   # emote downloads against Twitch's CDN
python scripts\check_lua.py   # compile every Lua file (pip install lupa)
python scripts\smoke_lua.py   # run the mod against a UE4SS stub
scripts\Get-UE4SS.ps1 -Zip <UE4SS standard zip>   # the UE4SS build to bundle (hash-checked)
scripts\Build-Release.ps1     # dist\RunningTrain-TwitchTablet-<version>.zip
```

`scripts\Dev-Install.ps1` / `Dev-Uninstall.ps1` make the game load the mod
straight from this repository, and the mod reloads itself when a file changes.

---

## Credits

Made by [churuya](https://steamcommunity.com/id/iamsoslow) and Claude (Anthropic).

Built on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) by Narknon and
contributors, bundled unmodified under its MIT license.

Licensed under the [MIT License](LICENSE).
