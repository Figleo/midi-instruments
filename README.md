# Barotrauma MIDI Instruments

A LuaCs mod for Barotrauma that allows players to play custom **.mid / .midi** files on instruments in-game, complete with multi-track support, sound bank selection, multiplayer syncing, and a customizable GUI.

[![Steam Workshop](https://img.shields.io/badge/Steam_Workshop-MIDI_Instruments-blue?style=for-the-badge&logo=steam)](https://steamcommunity.com/sharedfiles/filedetails/?id=3692939185)
[![MIDI Storage](https://img.shields.io/badge/Steam_Workshop-MIDI_Storage-green?style=for-the-badge&logo=steam)](https://steamcommunity.com/workshop/filedetails/?id=3695216167)


## Features

- **Interactive GUI**: Opens automatically when holding an instrument or toggled via **F5**. Includes real-time search, progress scrubbing, and status displays.
- **Multi-Instrument & Sound Bank Switching**:
  - 🎸 **Electric Guitar**: Switch modes on the fly between **Classic**, **Lead**, **Crunch**, and **Bass**.
  - 🪕 **Acoustic Guitar**: Switch modes on the fly between **Steel**, **Acoustic**, and **Fingers Soft**.
  - 🪗 **Accordion** & 🪗 **Harmonica**.
- **Multiplayer Jamming ("Play Together")**: Automatically detects other crew members playing music and allows joining them to perform in sync.
- **Talent Buffs**: Enable or disable playing-triggered talent buffs directly from the interface.
- **Dynamic Volume Control**: Integrates with mod settings to control playback volume dynamically.

## Instrument sound range

Use the console command `midirange` to show the current radius, or `midirange 2000`
to set one radius for all instruments and sound banks. The default is `1000`;
accepted values are whole numbers from `100` to `50000` in game units.

In multiplayer, only the host can change it. The server broadcasts the value to
all clients, including players who join later. On a dedicated server, run the
command in the server console. Singleplayer and the main menu allow local changes.
Changes apply to newly played notes; sustained notes keep their original radius.

The server (or singleplayer) saves the value to
`<game save folder>/ModConfigs/MidiInstruments_Range.txt`. Joining another host
does not overwrite your saved setting. Playback still uses `Sound.Play` for
Soundproof Walls compatibility; SPW's `RangeMult` does not multiply this radius.

## Soundproof Walls: preserve MIDI pitch at a distance and in motion

This mod includes a client-only compatibility patch for Soundproof Walls. You
can leave **Pitch With Distance** and **Doppler Effect** enabled in SPW: they
still affect other sounds, but are skipped for this mod's nine MIDI sample
banks. The distance patch refines one
boolean check in SPW's original `ChannelInfo.UpdatePitch` method; it does not
replace the pitch formula or edit SPW's DLL. MIDI transposition,
other SPW pitch effects, muffling and reverb retain their existing behavior.
Your `ReverbForcedSounds` and `XMLIgnoredSounds` entries can stay as configured.
Do not add MIDI samples to `PitchIgnoredSounds`, which forces pitch to `1.0`.

Doppler is disabled through OpenAL Soft's **per-source** `AL_DOPPLER_FACTOR`,
before a MIDI channel starts playback. This excludes both emitter movement and
listener movement without changing musical pitch, spatial positioning or
SPW's global doppler settings. The previous source factor is restored on
disposal, reuse or mod unload so pooled sources retain normal behavior for
other sounds. No extra SPW list entry or button press is needed for this patch.

To configure muffling and reverb, open **Settings → Mod Gameplay Settings →
MIDI Instruments** and press **SPW patch** below the MIDI volume control. This
adds `notes` to **XML Ignored Sounds** (`XMLIgnoredSounds`) and **Reverb Forced
Sounds** (`ReverbForcedSounds`). Each list is checked independently, ignoring
letter case, so repeated clicks do not add duplicates. Existing entries and
other preferences are preserved. SPW saves its own configuration to
`<game save folder>/ModConfigs/SoundproofWalls_Config.json` and refreshes sound
metadata using its normal settings API.

The button acts immediately and displays the result; the MIDI menu's Apply or
Reset buttons do not run it. Nothing adds `notes` on startup, so players can
remove or change these entries later in SPW's settings. This button configures
the two lists; the automatic distance-pitch compatibility patch above runs
independently of it.

If SPW is using synchronized server settings, the host or a player with
**Manage Settings** permission can press the same button to send the updated
server lists through SPW. This preserves the active server's other preferences
and each user's local preferences. Guests save their local lists; if the
server lists are missing `notes`, the result explains that the host needs to
apply it. With synchronization disabled, each player applies their local lists.

Every player, including the host's client, needs the updated MIDI mod and LuaCs
with C# mods enabled (also required for SPW itself). LuaCs compiles
`CSharp/SpwDistancePitch.cs` automatically through `ModConfig.xml`; players do not
need the .NET SDK, a separate patch mod or a replacement SPW DLL. Restart/reload
mods after installing the update. No compatibility assembly runs on the server.

Successful client startup logs `[MidiMod] [SPW compatibility] Applied`. If a
future SPW version changes the relevant method, the patch reports
`Incompatible SPW` and leaves SPW's original calculation in place. Without SPW,
ordinary MIDI playback is unaffected. Disabling/reloading the mod removes only
its own Harmony patch.

Developer validation lives in `tests/SPWCompat`. With .NET SDK 8 installed, run
`dotnet build --configuration Release --configfile NuGet.Config` from that folder,
then run `dotnet bin/Release/net8.0/SPWCompat.Tests.dll <Barotrauma directory> <SPW client DLL>`.
The second argument verifies the installed SPW method without playing game audio
or writing to its files. The build uses local game/Harmony references and no
NuGet packages. Python startup/network checks run with `python -m pytest tests`;
they require `pytest` and `lupa`.

## Adding Custom MIDI Files

MIDI files are loaded from the **MIDI Storage** workshop item or your local mod directory depending on debug settings.

### Option 1: Via Workshop (Default / Normal Mode)
Install the [MIDI Storage Mod](https://steamcommunity.com/workshop/filedetails/?id=3695216167) and place `.mid` / `.midi` files into its directory:
- **Windows**: `C:\Users\<User>\AppData\Local\Daedalic Entertainment GmbH\Barotrauma\WorkshopMods\Installed\3695216167\`
- **Linux**: `~/.local/share/Daedalic Entertainment GmbH/Barotrauma/WorkshopMods/Installed/3695216167/Midi/`

### Option 2: Local Mod Folder (Debug Mode)
Files will be read automatically from `<ModDirectory>/Midi/`

## Controls & Usage

1. **Equip an Instrument**: Hold any supported instrument in hands.
2. **Open Menu**: The panel will pop up automatically (or press **F5** to toggle visibility).
3. **Select a Track & Play**: Use the search bar to find a song, click **Play**, or drag the progress slider to scrub through the track.
4. **Change Sound Modes**: For Electric and Acoustic Guitars, a side panel allows switching sound banks in real-time.

---

## Credits

* **Arachno SoundFont** by [Maxime Abbey (Arachnosoft)](http://www.arachnosoft.com/)
* **Renoise Instruments & SoundFonts** by [jbbourgoin](https://github.com/jbbourgoin/renoise-instruments)
* **FSBS Electric Guitar SoundFonts** by [FreePats](https://freepats.zenvoid.org/)
