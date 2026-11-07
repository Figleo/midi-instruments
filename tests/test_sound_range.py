"""Exercise Lua modules with simulated game, network and file APIs."""
from pathlib import Path
import xml.etree.ElementTree as ET

import pytest
from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = "/save/ModConfigs/MidiInstruments_Range.txt"
HARNESS = """
logs, commands, remoteCommands, hooks, receivers, sent, files = {}, {}, {}, {}, {}, {}, {}
writeCount, now = 0, 0
os.clock = function() return now end
MidiMod = { Log = function(text) logs[#logs + 1] = text end }
File = {
    Exists = function(path) return files[path] ~= nil end,
    Read = function(path) return files[path] end,
    CreateDirectory = function() end,
    Write = function(path, text)
        if failSave then error("disk unavailable") end
        files[path] = text
        writeCount = writeCount + 1
    end
}
TextManager = { Get = function(key) return { Value = key .. " [range]" } end }
Game = {
    SaveFolder = "/save", IsSingleplayer = false,
    RemoveCommand = function(name) commands[name] = nil end,
    AddCommand = function(name, _, callback) commands[name] = callback end,
    AssignOnClientRequestExecute = function(name, callback) remoteCommands[name] = callback end
}
Client = { ClientList = {} }
Hook = { Add = function(event, name, callback)
    hooks[event] = hooks[event] or {}
    hooks[event][name] = callback
end }
function packet(name)
    local msg = { name = name, data = {}, cursor = 0 }
    msg.WriteUInt16 = function(value) msg.data[#msg.data + 1] = value end
    msg.WriteString = function(value) msg.data[#msg.data + 1] = value end
    local function read()
        msg.cursor = msg.cursor + 1
        return msg.data[msg.cursor]
    end
    msg.ReadUInt16, msg.ReadString = read, read
    return msg
end
Networking = {
    Start = packet,
    Receive = function(name, callback) receivers[name] = callback end,
    Send = function(msg, connection)
        if failSend then error("connection not ready") end
        sent[#sent + 1] = { message = msg, connection = connection }
    end
}
function runCommand(...)
    local words, index = {...}, 0
    commands.midirange(function()
        index = index + 1
        return words[index]
    end)
end
function runRemoteCommand(sender, ...)
    local words, index = {...}, 0
    remoteCommands.midirange(sender, nil, function()
        index = index + 1
        return words[index]
    end)
end
function runHooks(event)
    for _, callback in pairs(hooks[event] or {}) do callback() end
end
function receive(name, sender, ...)
    local msg = packet(name)
    msg.data = {...}
    receivers[name](msg, sender)
end
"""


class GameEnv:
    def __init__(self, *, server=False, owner=False, single=False, saved=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(HARNESS)
        self.g = self.lua.globals()
        self.g.package.path = str(ROOT / "Lua" / "?.lua").replace("\\", "/") + ";" + self.g.package.path
        self.g.SERVER, self.g.CLIENT = server, not server
        self.g.Game.IsSingleplayer = single
        if server:
            self.g.Game.Server = self.lua.table_from({"OwnerConnection": "host"})
            self.g.Client.ClientList = self.lua.table_from([
                self.client("host"), self.client("guest")
            ])
        elif not single:
            self.g.Game.Client = self.lua.table_from({"IsServerOwner": owner})
        if saved is not None:
            self.g.files[CONFIG_PATH] = str(saved)
        self.load("range_config")

    def client(self, connection):
        return self.lua.table_from({"Connection": connection})

    def load(self, name):
        self.lua.execute((ROOT / "Lua" / f"{name}.lua").read_text(encoding="utf-8"))

    def command(self, *args):
        self.g.runCommand(*map(str, args))

    def receive(self, name, sender=None, *values):
        self.g.receive(name, sender, *values)

    def messages(self, name):
        return [entry for entry in self.g.sent.values() if entry.message.name == name]


def test_singleplayer_default_persistence_and_restart():
    game = GameEnv(single=True)
    assert game.g.MidiMod.SoundRange == 1000
    game.command(2400)
    assert game.g.MidiMod.SoundRange == 2400
    assert game.g.files[CONFIG_PATH] == "2400\n"
    restarted = GameEnv(single=True, saved=game.g.files[CONFIG_PATH])
    assert restarted.g.MidiMod.SoundRange == 2400
    restarted.command()
    assert restarted.g.logs[len(restarted.g.logs)] == "[midirange] Instrument sound range: 2400."


@pytest.mark.parametrize("args", [
    ("nan",), ("inf",), ("-inf",), ("bad",), (99,), (50001,),
    (1000.5,), (2000, 3000),
])
def test_invalid_commands_do_not_change_or_save(args):
    game = GameEnv(single=True)
    game.command(*args)
    assert game.g.MidiMod.SoundRange == 1000
    assert game.g.writeCount == 0


@pytest.mark.parametrize("saved", ["garbage", "nan", "100000", "-1", "200.5"])
def test_invalid_saved_value_uses_default(saved):
    assert GameEnv(single=True, saved=saved).g.MidiMod.SoundRange == 1000


def test_server_enforces_owner_even_if_guest_spoofs_owner_field():
    server = GameEnv(server=True)
    guest = server.client("guest")
    guest.IsOwner = True
    server.receive("MidiMod.Range.Set", guest, 3000)
    assert server.g.MidiMod.SoundRange == 1000
    assert server.g.writeCount == 0
    reply = server.messages("MidiMod.Range.Result")[-1]
    assert reply.connection == "guest"
    assert reply.message.data[2] == "hostonly"


def test_remote_console_cannot_bypass_host_permission():
    server = GameEnv(server=True)
    server.g.runRemoteCommand(server.client("guest"), "3000")
    assert server.g.MidiMod.SoundRange == 1000
    assert server.g.writeCount == 0
    assert server.messages("MidiMod.Range.Result")[-1].message.data[2] == "hostonly"
    server.g.runRemoteCommand(server.client("host"), "3000")
    assert server.g.MidiMod.SoundRange == 3000
    server.g.runRemoteCommand(server.client("guest"))
    assert server.messages("MidiMod.Range.Result")[-1].message.data[2] == "current"


@pytest.mark.parametrize("value", [0, 99, 50001, 65535])
def test_server_rejects_invalid_range_in_packets(value):
    server = GameEnv(server=True)
    server.receive("MidiMod.Range.Set", server.client("host"), value)
    assert server.g.MidiMod.SoundRange == 1000
    assert server.g.writeCount == 0


@pytest.mark.parametrize("value", [100, 50000])
def test_range_boundaries_are_accepted(value):
    game = GameEnv(single=True)
    game.command(value)
    assert game.g.MidiMod.SoundRange == value


def test_host_update_reaches_every_client_and_late_joiner():
    server = GameEnv(server=True)
    server.receive("MidiMod.Range.Set", server.client("host"), 3200)
    assert server.g.MidiMod.SoundRange == 3200
    assert server.g.files[CONFIG_PATH] == "3200\n"
    assert {msg.connection for msg in server.messages("MidiMod.Range.State")} == {
        "host", "guest"
    }
    guest = GameEnv(saved=1700)
    assert guest.messages("MidiMod.Range.Get")
    server.receive("MidiMod.Range.Get", server.client("late"))
    reply = server.messages("MidiMod.Range.State")[-1]
    assert reply.connection == "late"
    guest.receive("MidiMod.Range.State", None, reply.message.data[1])
    assert guest.g.MidiMod.SoundRange == 3200
    assert guest.g.files[CONFIG_PATH] == "1700"
    assert guest.g.writeCount == 0


def test_owner_client_sends_request_and_waits_for_server():
    host = GameEnv(owner=True)
    host.command(4000)
    request = host.messages("MidiMod.Range.Set")[-1]
    assert request.message.data[1] == 4000
    assert host.g.MidiMod.SoundRange == 1000
    host.receive("MidiMod.Range.Result", None, 4000, "changed")
    assert host.g.MidiMod.SoundRange == 4000
    assert host.g.writeCount == 0


def test_guest_command_is_read_only_and_query_asks_server():
    guest = GameEnv(saved=1700)
    guest.command(4000)
    assert not guest.messages("MidiMod.Range.Set")
    guest.command()
    assert len(guest.messages("MidiMod.Range.Get")) == 2
    guest.receive("MidiMod.Range.State", None, 2400)
    assert guest.g.logs[len(guest.g.logs)] == "[midirange] Instrument sound range: 2400."


def test_missing_connection_is_retried_and_new_server_resynchronizes():
    guest = GameEnv(saved=1700)
    guest.g.failSend = True
    guest.g.now = 3
    guest.g.runHooks("think")
    guest.g.failSend = False
    guest.g.now = 6
    guest.g.runHooks("think")
    assert len(guest.messages("MidiMod.Range.Get")) == 2
    guest.receive("MidiMod.Range.State", None, 3500)
    guest.g.now = 9
    guest.g.runHooks("think")
    assert len(guest.messages("MidiMod.Range.Get")) == 2
    guest.g.Game.Client = None
    guest.g.runHooks("think")
    assert guest.g.MidiMod.SoundRange == 1700
    guest.g.Game.Client = guest.lua.table_from({"IsServerOwner": False})
    guest.g.runHooks("think")
    assert len(guest.messages("MidiMod.Range.Get")) == 3
    guest.receive("MidiMod.Range.State", None, 2200)
    assert guest.g.MidiMod.SoundRange == 2200
    guest.g.runHooks("roundStart")
    assert len(guest.messages("MidiMod.Range.Get")) == 4


def test_dedicated_console_persists_and_broadcasts():
    server = GameEnv(server=True)
    server.g.Game.Server.OwnerConnection = None
    server.command(5000)
    assert server.g.files[CONFIG_PATH] == "5000\n"
    assert len(server.messages("MidiMod.Range.State")) == 2
    server.receive("MidiMod.Range.Set", server.client("guest"), 2000)
    assert server.g.MidiMod.SoundRange == 5000


def test_save_failure_is_reported_but_session_value_is_synchronized():
    server = GameEnv(server=True, saved=1000)
    server.g.failSave = True
    server.receive("MidiMod.Range.Set", server.client("host"), 3000)
    assert server.g.MidiMod.SoundRange == 3000
    assert server.g.files[CONFIG_PATH] == "1000"
    assert server.messages("MidiMod.Range.Result")[-1].message.data[2] == "savefailed"
    assert len(server.messages("MidiMod.Range.State")) == 2


def test_new_notes_use_shared_range_keep_pitch_and_old_channels_keep_radius():
    game = GameEnv(single=True)
    game.load("sound_engine")
    game.lua.execute("""
        Vector2 = function(x, y) return { X = x, Y = y } end
        Vector3 = function(x, y, z) return { X = x, Y = y, Z = z } end
        played = {}
        local sound = { DurationSeconds = 1 }
        sound.Play = function(gain, range, pitch, pos)
            local channel = { IsPlaying = true, Far = range, Pitch = pitch }
            channel.Dispose = function() channel.IsPlaying = false end
            channel.FadeOutAndDispose = channel.Dispose
            played[#played + 1] = { range = range, channel = channel }
            return channel
        end
        MidiMod.SoundEngine.initialized = true
        for _, inst in ipairs({"accordion", "guitar", "guitarelectric",
            "guitarelectric_lead", "guitarelectric_crunch", "guitarelectric_bass",
            "guitar_acoustic", "guitar_acoustic_soft", "harmonica"}) do
            MidiMod.SoundEngine.soundBanks[inst] = { [60] = { sound } }
            MidiMod.SoundEngine.soundBankIdx[inst] = { [60] = 0 }
        end
        MidiMod.SoundEngine.playNote(60, 100, Vector2(0, 0), "accordion", 1)
        oldChannel = played[1].channel
        runCommand("3600")
        for _, inst in ipairs({"accordion", "guitar", "guitarelectric",
            "guitarelectric_lead", "guitarelectric_crunch", "guitarelectric_bass",
            "guitar_acoustic", "guitar_acoustic_soft", "harmonica"}) do
            MidiMod.SoundEngine.playNote(72, 100, Vector2(0, 0), inst, 2)
        end
    """)
    assert game.g.oldChannel.Far == 1000
    assert len(game.g.played) == 10
    for index in range(2, 11):
        note = game.g.played[index]
        assert note.range == note.channel.Far == 3600
        assert note.channel.Pitch == 2
        assert note.channel.Looping is True


def test_localized_console_messages_exist_in_both_languages():
    keys = {"help", "current", "changed", "invalid", "hostonly", "waiting", "savefailed"}
    for language in ("English", "Russian"):
        root = ET.parse(ROOT / "Texts" / f"{language}.xml").getroot()
        assert all(root.find(f"midirange.{key}") is not None for key in keys)
