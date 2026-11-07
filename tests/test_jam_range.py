"""Exercise Play Together with moving characters and network messages."""
from pathlib import Path

import pytest
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
HARNESS = """
now = 1
os.clock = function() return now end
logs, hooks, receivers, sent, calls, played, stopped, released, commands, files = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
MidiMod = {
    Log = function(text) logs[#logs + 1] = text end,
    DebugLog = function() end,
    Instruments = { accordion = true }, BuffsEnabled = true,
    IsHoldingInstrument = function(ch) return ch and ch.item ~= nil end,
    GetHeldInstrument = function(ch) if ch and ch.item then return 'accordion', ch.item end end,
    ActiveSoundBank = function(name) return name end,
    SoundEngine = {
        stopAllForChar = function(id) stopped[#stopped + 1] = id end,
        stopAll = function() end,
        playNote = function(note, velocity, pos, inst, id) played[#played + 1] = id end,
        releaseNote = function(note, id) released[#released + 1] = id end,
    }
}
function character(id, x, y)
    local pos = { X = x, Y = y }
    return { ID = id, WorldPosition = pos, item = { WorldPosition = pos }, Removed = false, IsDead = false }
end
entities = { [1] = character(1, 0, 0), [2] = character(2, 1500, 0), [3] = character(3, 2000, 0) }
Character = { Controlled = entities[1] }
Entity = { FindEntityByID = function(id) return entities[id] end }
Game = {
    IsSingleplayer = false, SaveFolder = '/save', Server = { OwnerConnection = 'sender' },
    RemoveCommand = function(name) commands[name] = nil end,
    AddCommand = function(name, _, callback) commands[name] = callback end,
    AssignOnClientRequestExecute = function() end
}
File = {
    Exists = function(path) return files[path] ~= nil end,
    Read = function(path) return files[path] end,
    CreateDirectory = function() end,
    Write = function(path, text) files[path] = text end
}
function runGroupCommand(value)
    local read = false
    commands.midijamrange(function()
        if read then return nil end
        read = true
        return value
    end)
end
TextManager = { Get = function(key) return { Value = key .. ' [range]' } end }
InputType = { Aim = 2 }
LuaUserData = { CreateStatic = function() return {} end }
Hook = {
    HookMethodType = { After = 1 }, Patch = function() end,
    Add = function(_, name, callback) hooks[name] = callback end,
    Call = function(name, id) calls[#calls + 1] = { name, id } end
}
sender = { Character = entities[1], Connection = 'sender' }
Client = { ClientList = { sender, { Character = entities[3], Connection = 'other' } } }
function packet(name, values)
    local msg = { name = name, data = values or {}, cursor = 0 }
    msg.WriteUInt16 = function(value) msg.data[#msg.data + 1] = value end
    msg.WriteString = msg.WriteUInt16
    local function read() msg.cursor = msg.cursor + 1; return msg.data[msg.cursor] end
    msg.ReadUInt16, msg.ReadString = read, read
    return msg
end
Networking = {
    Start = packet,
    Receive = function(name, callback) receivers[name] = callback end,
    Send = function(msg, connection) sent[#sent + 1] = { message = msg, connection = connection } end
}
function receive(name, ...)
    receivers[name](packet(name, {...}), sender)
end
"""


class JamEnv:
    def __init__(self, *, server=False):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(HARNESS)
        self.g = self.lua.globals()
        self.g.package.path = str(ROOT / "Lua" / "?.lua").replace("\\", "/") + ";" + self.g.package.path
        self.g.SERVER, self.g.CLIENT = server, not server
        for name in ("jam_range", "player", "network"):
            self.lua.execute((ROOT / "Lua" / f"{name}.lua").read_text(encoding="utf-8"))
        self.p = self.g.MidiMod.Player
        self.n = self.g.MidiMod.Network
        self.n.init()
        self.announce(2)

    def announce(self, id):
        self.p.activePerformers[id] = self.lua.table_from({"fileName": "song.mid", "receivedAt": self.g.now})

    def move(self, id, x, y=0):
        self.g.entities[id].WorldPosition.X = x
        self.g.entities[id].WorldPosition.Y = y

    def messages(self, name):
        return [s.message for s in self.g.sent.values() if s.message.name == name]

    def receive(self, name, *args):
        self.g.receive(name, *args)

    def pump(self):
        self.g.now += 0.1
        self.g.hooks["MidiMod.Network.JitterPump"]()


@pytest.mark.parametrize("x,y,allowed", [
    (1999, 0, True), (2000, 0, True), (2001, 0, False),
    (0, -2000, True), (1200, 1600, True), (1500, 1500, False),
    (float("nan"), 0, False), (float("inf"), 0, False),
])
def test_radius_boundary_and_world_coordinates(x, y, allowed):
    env = JamEnv()
    env.move(2, x, y)
    assert env.g.MidiMod.CanJamWith(env.g.entities[1], 2) is allowed
    assert (env.p.getPerformers()[2] is not None) is allowed


def test_missing_removed_or_self_character_cannot_join():
    env = JamEnv()
    assert not env.g.MidiMod.CanJamWith(None, 2)
    assert not env.g.MidiMod.CanJamWith(env.g.entities[1], 999)
    assert not env.g.MidiMod.CanJamWith(env.g.entities[1], 1)
    env.g.entities[2].Removed = True
    assert not env.g.MidiMod.CanJamWith(env.g.entities[1], 2)


def test_distant_performer_stays_known_and_reappears_when_near():
    env = JamEnv()
    env.move(2, 2500)
    assert env.p.getPerformers()[2] is None
    assert env.p.activePerformers[2] is not None
    env.move(2, 1800)
    assert env.p.getPerformers()[2] is not None


def test_join_rechecks_range_without_stopping_current_song():
    env = JamEnv()
    assert env.p.getPerformers()[2] is not None
    env.p.playing = True
    env.move(2, 2001)
    assert env.n.requestJoin(2) == (False, "outofrange")
    assert env.p.playing
    assert env.p.jamLeaderID is None
    assert len(env.g.sent) == 0


def test_join_inside_radius_and_leave_on_movement():
    env = JamEnv()
    assert env.n.requestJoin(2)
    assert env.p.jamLeaderID == 2
    env.n.playStreamedNotes(2, "60,100", "accordion")
    env.move(2, 2001)
    env.g.hooks["MidiMod.Player.Think"]()
    assert env.p.jamLeaderID is None
    assert 1 in list(env.g.stopped.values())
    assert env.messages("MidiMod.Stop")[-1].data[1] == 1
    env.pump()
    assert 1 not in list(env.g.played.values())
    assert 2 in list(env.g.played.values())


def test_server_rejects_remote_join_and_uses_actual_sender_id():
    env = JamEnv(server=True)
    env.move(2, 2001)
    env.receive("MidiMod.JamAnnounce", 999, "", 2, 0, 0, "accordion")
    assert len(env.messages("MidiMod.JamAnnounce")) == 0
    stops = env.messages("MidiMod.Stop")
    assert len(stops) == 2
    assert all(p.data[1] == 1 for p in stops)
    assert env.g.calls[1][1] == "MidiMod.Server.BuffStop"
    assert env.g.calls[1][2] == 1


def test_server_allows_join_at_boundary_and_unlimited_solo_announcements():
    env = JamEnv(server=True)
    env.move(2, 2000)
    env.receive("MidiMod.JamAnnounce", 999, "", 2, 0, 0, "accordion")
    packet = env.messages("MidiMod.JamAnnounce")[0]
    assert packet.data[1] == 1 and packet.data[3] == 2
    env.move(2, 9000)
    env.receive("MidiMod.JamAnnounce", 1, "solo.mid", 0, 0, 0, "accordion")
    assert len(env.messages("MidiMod.JamAnnounce")) == 2


def test_server_rejection_clears_own_optimistic_mirror_state():
    env = JamEnv()
    env.n.requestJoin(2)
    env.receive("MidiMod.Stop", 1)
    assert env.p.jamLeaderID is None


def test_remote_mirror_filter_cuts_only_out_of_range_copies():
    env = JamEnv()
    env.receive("MidiMod.JamAnnounce", 3, "", 2, 0, 0, "accordion")
    assert list(env.p.getMirrorsOf(2).values()) == [3]
    env.n.playStreamedNotes(2, "60,100", "accordion")
    env.move(3, 4000)
    assert env.p.getMirrorsOf(2) is None
    assert env.p.jamMirrors[3] is None
    env.pump()
    assert list(env.g.played.values()) == [2]
    assert 3 in list(env.g.stopped.values())


def test_jitter_delay_rechecks_mirror_distance_before_playing():
    env = JamEnv()
    env.receive("MidiMod.JamAnnounce", 3, "", 2, 0, 0, "accordion")
    env.n.playStreamedNotes(2, "60,100", "accordion")
    env.move(3, 4000)
    env.pump()
    assert list(env.g.played.values()) == [2]
    assert 3 in list(env.g.stopped.values())


def test_distant_incoming_mirror_announcement_is_discarded():
    env = JamEnv()
    env.move(3, 4000)
    env.receive("MidiMod.JamAnnounce", 3, "", 2, 0, 0, "accordion")
    assert env.p.jamMirrors[3] is None


def test_radius_changes_apply_to_existing_groups_without_reload():
    env = JamEnv()
    assert env.n.requestJoin(2)
    env.g.runGroupCommand("1000")
    assert env.g.MidiMod.JamRange == 1000
    env.g.hooks["MidiMod.Player.Think"]()
    assert env.p.jamLeaderID is None
    env.g.runGroupCommand("3000")
    env.move(2, 2500)
    assert env.p.getPerformers()[2] is not None
    assert env.n.requestJoin(2)
