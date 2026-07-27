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

## Adding Custom MIDI Files

MIDI files are loaded from the **MIDI Storage** workshop item or your local mod directory depending on debug settings.

### Option 1: Via Workshop (Default / Normal Mode)
Install the [MIDI Storage Mod](https://steamcommunity.com/workshop/filedetails/?id=3695216167) and place `.mid` / `.midi` files into its directory:
- **Windows**: `C:\Users\<User>\AppData\Local\Daedalic Entertainment GmbH\Barotrauma\WorkshopMods\Installed\3695216167\`
- **Linux**: `~/.local/share/Daedalic Entertainment GmbH/Barotrauma/WorkshopMods/Installed/3695216167/Midi/`

### Option 2: Local Mod Folder (Debug Mode)
When `MidiMod.Debug = true` in `Lua/Autorun/init.lua`, files will be read directly from:
- `<ModDirectory>/Midi/`

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