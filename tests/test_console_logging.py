"""Check real module startup, local debug commands and quiet background work."""
import xml.etree.ElementTree as ET

import pytest
from lupa import LuaRuntime

from test_jam_range import HARNESS, ROOT


class ConsoleEnv:
    def __init__(self, *, server=False, fail_module=False):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(HARNESS)
        self.g = self.lua.globals()
        self.g.SERVER, self.g.CLIENT = server, not server
        self.g.Game.IsSingleplayer = not server
        self.g.package.path = str(ROOT / "Lua" / "?.lua").replace("\\", "/") + ";" + self.g.package.path
        self.lua.execute("""
            print = function(text) logs[#logs + 1] = text end
            remoteCommands = {}
            Game.AssignOnClientRequestExecute = function(name, callback) remoteCommands[name] = callback end
            Hook.Remove = function(_, name) hooks[name] = nil end
            compat = {
                Status = 'Soundproof Walls is not loaded',
                ConfigureModDirectory = function() end,
                TryInstallPatch = function() end,
            }
            LuaUserData.RegisterType = function() end
            LuaUserData.CreateStatic = function(name)
                if name == 'MidiInstruments.Compatibility.SpwDistancePitch' then return compat end
                return {}
            end
            MidiMod.Debug = true
            files['/save/ModConfigs/MidiInstruments_Range.txt'] = '1500'
            function runDebugCommand(...)
                local words, index = {...}, 0
                commands.mididebug(function()
                    index = index + 1
                    return words[index]
                end)
            end
        """)
        if fail_module:
            self.lua.execute("""
                local original = require
                require = function(name)
                    if name == 'gui' then error('GUI unavailable') end
                    return original(name)
                end
            """)
        self.lua.execute((ROOT / "Lua/Autorun/init.lua").read_text(encoding="utf-8"), str(ROOT) + "/")

    def logs(self):
        return list(self.g.logs.values())

    def command(self, *args):
        self.g.runDebugCommand(*args)


def test_client_startup_prints_only_five_lines_and_finishes_loading():
    env = ConsoleEnv()
    version = ET.parse(ROOT / "filelist.xml").getroot().get("modversion")
    assert env.logs() == [
        f"[MidiMod] === MIDI Instruments v{version} ===",
        f"[MidiMod] Base path: {ROOT}/",
        "[MidiMod] [midirange] Range: 1500; file: /save/ModConfigs/MidiInstruments_Range.txt",
        "[MidiMod] [midijamrange] Range: 2000; file: /save/ModConfigs/MidiInstruments_JamRange.txt",
        "[MidiMod] [SPW compatibility] Soundproof Walls is not loaded",
    ]
    assert env.g.MidiMod.Debug is False
    for module in ("MidiParser", "SoundEngine", "Player", "Network", "GUI"):
        assert env.g.MidiMod[module] is not None
    assert env.g.receivers["MidiMod.Notes"] is not None
    assert env.g.commands.mididebug is not None


def test_background_loading_and_spw_retries_stay_quiet():
    env = ConsoleEnv()
    before = env.logs()
    for _ in range(100):
        env.g.hooks.midi_sound_tick()
    assert env.g.MidiMod.SoundEngine.initialized is True
    env.g.MidiMod.Player.play()
    env.g.compat.Status = "Applied"
    env.g.now = 3
    env.g.hooks["MidiMod.SpwCompatibility.Load"]()
    assert env.g.hooks["MidiMod.SpwCompatibility.Load"] is None
    assert env.logs() == before


def test_command_enables_and_disables_lua_and_csharp_logs():
    env = ConsoleEnv()
    env.command("ON")
    assert env.g.MidiMod.Debug is True
    assert env.g.compat.DebugEnabled is True
    env.g.MidiMod.Player.play()
    assert env.logs()[-1] == "[MidiMod:Debug] No MIDI loaded to play"
    env.command("off")
    assert env.g.MidiMod.Debug is False
    assert env.g.compat.DebugEnabled is False
    before = env.logs()
    env.g.MidiMod.Player.play()
    assert env.logs() == before
    assert before[-1] == "[MidiMod] [mididebug] Debug logging: off."


@pytest.mark.parametrize("args", [("invalid",), ("on", "off")])
def test_invalid_debug_command_preserves_setting(args):
    env = ConsoleEnv()
    env.command("on")
    env.command(*args)
    assert env.g.MidiMod.Debug is True
    assert env.g.compat.DebugEnabled is True
    assert env.logs()[-1] == "[MidiMod] [mididebug] Usage: mididebug [on|off]."


def test_debug_query_and_range_replies_remain_visible_without_debug():
    env = ConsoleEnv()
    env.command()
    assert env.logs()[-1] == "[MidiMod] [mididebug] Debug logging: off."
    env.g.runGroupCommand(None)
    assert env.logs()[-1] == "[MidiMod] [midijamrange] Play Together radius: 2000."
    assert env.g.MidiMod.Debug is False


def test_server_debug_is_local_and_has_no_spw_dependency():
    env = ConsoleEnv(server=True)
    assert len(env.logs()) == 4
    env.g.remoteCommands.mididebug()
    assert env.g.MidiMod.Debug is False
    env.command("on")
    assert env.g.MidiMod.Debug is True
    assert env.g.MidiMod.SpwCompatibility is None
    env.command("off")
    assert env.g.MidiMod.Debug is False


def test_failed_module_does_not_add_normal_console_messages():
    env = ConsoleEnv(fail_module=True)
    assert len(env.logs()) == 5
    assert env.g.MidiMod.GUI is None
