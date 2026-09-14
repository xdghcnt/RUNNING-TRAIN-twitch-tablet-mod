================================================================================
  RUNNING TRAIN - Twitch Tablet
  by churuya and Claude
================================================================================

A physical tablet in the driver's cab of RUNNING TRAIN / 走ル列車！ that shows
your Twitch chat on its screen, emotes included. It rides with the train like a
phone clipped to the desk. Chat is read anonymously: no login, nothing to
authorise.

Ready-made tablet positions for hr1500, hr1100, kr5000 and DC8500. In any other
train the tablet appears right in front of you, and you place it once.


--------------------------------------------------------------------------------
INSTALL
--------------------------------------------------------------------------------

Extract the contents of this archive into the folder that holds the real game
executable:

    ...\Steam\steamapps\common\RUNNING TRAIN\RunningTrain\Binaries\Win64\

You should end up with "dwmapi.dll" and a folder "ue4ss" sitting next to
"RunningTrain-Win64-Shipping.exe".

Already have the HeadTracking mod? Extract over it and allow the overwrite. The
shared UE4SS files are identical, and both mods keep working.


--------------------------------------------------------------------------------
SET YOUR CHANNEL
--------------------------------------------------------------------------------

Start the game once and get into a cab; the tablet says "Set Channel in
TwitchTablet.ini". Open

    ue4ss\Mods\RunningTrainTwitchTablet\TwitchTablet.ini

and write your channel, as in twitch.tv/<channel>:

    [Twitch]
    Channel = yourchannel

Save the file. The mod picks it up within a few seconds, with no restart.


--------------------------------------------------------------------------------
KEYS  (numpad; every key can be changed, see CONFIG)
--------------------------------------------------------------------------------

    Num1        hide / show the tablet
    Num2        screen off / on
    Num4 / Num6 chat font smaller / bigger
    Num7 / Num9 screen dimmer / brighter
    Num8        disconnect from / reconnect to Twitch
    Num0        calibration mode (placing the tablet) on / off
    Num5        connection status + frame-time sample into the log
    Num*        reload the mod and its config

  In calibration mode (Num0), a yellow band on the screen shows the mode:

    Num5          next mode: MOVE -> ROTATE -> SIZE
    Num4 / Num6   MOVE left/right    ROTATE turn     SIZE narrower/wider
    Num8 / Num2   MOVE fwd/back      ROTATE tilt     SIZE taller/shorter
    Num9 / Num3   MOVE up/down       ROTATE roll
    Num+ / Num-   scale the whole tablet
    Num/          put it right in front of your eyes, then fine-tune
    Enter         SAVE for this train (the band flashes SAVED)
    Num.          undo changes since the last save
    Num7          fine steps (x0.1) on / off
    hold Alt      big steps (x10)
    Num0          leave calibration

  The font size is saved with the train, too.


--------------------------------------------------------------------------------
CONFIG
--------------------------------------------------------------------------------

In ue4ss\Mods\RunningTrainTwitchTablet\ :

  TwitchTablet.default.ini  every option explained, plus the train presets.
                            Updates replace it, so do not edit it.
  TwitchTablet.ini          YOUR settings. They override the same keys in the
                            default file. Updates never touch it, and
                            calibration saves go here.

To change something, copy its line and its [Section] header from the default
file into TwitchTablet.ini, and edit it there.

No numpad? Remap in [Keys], for example:

    [Keys]
    Tablet = Insert
    Calibrate = Home
    CalLeft = Left
    CalRight = Right

Avoid keys 1-3 and the F-keys: the game uses them.


--------------------------------------------------------------------------------
TROUBLESHOOTING
--------------------------------------------------------------------------------

The log is ue4ss\UE4SS.log; the mod's lines start with [Tablet].

  No tablet            press Num1 (it may be hidden); wait a few seconds after
                       the route loads.
  Tablet in an odd     that train has no preset: Num0, then Num/, place it,
  place                then Enter.
  "waiting for chat"   check the channel name; press Num5 and look for the
                       [Twitch] line in the log. Only messages written after
                       you joined are shown.
  Antivirus warning    UE4SS loads through a proxy DLL, which heuristic
                       scanners dislike. The mod connects only to Twitch:
                       the chat server (read-only) and the emote images.


--------------------------------------------------------------------------------
UNINSTALL
--------------------------------------------------------------------------------

Delete ue4ss\Mods\RunningTrainTwitchTablet and
ue4ss\Mods\RunningTrainTwitchTabletNative. If no other UE4SS mod is left, also
delete dwmapi.dll and the ue4ss folder. The game's own files are never changed.


--------------------------------------------------------------------------------

Built on UE4SS (https://github.com/UE4SS-RE/RE-UE4SS), MIT license.
This mod: MIT license, see TwitchTablet-LICENSE.txt.
