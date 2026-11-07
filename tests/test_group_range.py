"""Verify group range permissions, persistence and independence from sound range."""
import xml.etree.ElementTree as ET

import pytest

from test_sound_range import GameEnv, ROOT

CONFIG_PATH = "/save/ModConfigs/MidiInstruments_JamRange.txt"


class GroupEnv(GameEnv):
    def __init__(self, *, saved=None, **kwargs):
        super().__init__(**kwargs)
        if saved is not None:
            self.g.files[CONFIG_PATH] = str(saved)
        self.load("jam_range")
        self.lua.execute("""
            function runGroupCommand(...)
                local words, index = {...}, 0
                commands.midijamrange(function()
                    index = index + 1
                    return words[index]
                end)
            end
            function runRemoteGroupCommand(sender, ...)
                local words, index = {...}, 0
                remoteCommands.midijamrange(sender, nil, function()
                    index = index + 1
                    return words[index]
                end)
            end
        """)

    def command(self, *args):
        self.g.runGroupCommand(*map(str, args))


def test_independent_defaults_saves_and_restart():
    game = GroupEnv(single=True)
    assert game.g.MidiMod.JamRange == 2000
    assert game.g.MidiMod.SoundRange == 1000
    game.command(3000)
    game.g.runCommand("4500")
    assert game.g.MidiMod.JamRange == 3000
    assert game.g.MidiMod.SoundRange == 4500
    assert game.g.files[CONFIG_PATH] == "3000\n"
    assert game.g.files["/save/ModConfigs/MidiInstruments_Range.txt"] == "4500\n"
    restarted = GroupEnv(single=True, saved=game.g.files[CONFIG_PATH])
    assert restarted.g.MidiMod.JamRange == 3000


@pytest.mark.parametrize("value", ["bad", "nan", "inf", "-inf", "99", "50001", "2000.5"])
def test_invalid_console_value_keeps_radius(value):
    game = GroupEnv(single=True)
    game.command(value)
    assert game.g.MidiMod.JamRange == 2000
    assert game.g.writeCount == 0


@pytest.mark.parametrize("value", [100, 50000])
def test_group_radius_boundaries(value):
    game = GroupEnv(single=True)
    game.command(value)
    assert game.g.MidiMod.JamRange == value


def test_corrupt_saved_value_uses_group_default():
    assert GroupEnv(single=True, saved="nan").g.MidiMod.JamRange == 2000


def test_only_host_changes_server_radius_even_through_remote_console():
    game = GroupEnv(server=True)
    guest = game.client("guest")
    guest.IsOwner = True
    game.receive("MidiMod.JamRange.Set", guest, 4000)
    assert game.g.MidiMod.JamRange == 2000
    assert game.messages("MidiMod.JamRange.Result")[-1].message.data[2] == "hostonly"
    game.g.runRemoteGroupCommand(guest, "4000")
    assert game.g.MidiMod.JamRange == 2000
    game.g.runRemoteGroupCommand(game.client("host"), "4000")
    assert game.g.MidiMod.JamRange == 4000
    assert game.g.MidiMod.SoundRange == 1000


def test_owner_client_waits_for_authoritative_reply():
    game = GroupEnv(owner=True)
    game.command(3500)
    assert game.messages("MidiMod.JamRange.Set")[-1].message.data[1] == 3500
    assert game.g.MidiMod.JamRange == 2000
    game.receive("MidiMod.JamRange.Result", None, 3500, "changed")
    assert game.g.MidiMod.JamRange == 3500
    assert game.g.writeCount == 0


def test_guest_query_and_late_join_preserve_local_saved_radius():
    server = GroupEnv(server=True)
    server.command(4200)
    guest = GroupEnv(saved=1700)
    guest.command(5000)
    assert not guest.messages("MidiMod.JamRange.Set")
    guest.command()
    server.receive("MidiMod.JamRange.Get", server.client("late"))
    reply = server.messages("MidiMod.JamRange.State")[-1]
    assert reply.connection == "late"
    guest.receive("MidiMod.JamRange.State", None, reply.message.data[1])
    assert guest.g.MidiMod.JamRange == 4200
    assert guest.g.files[CONFIG_PATH] == "1700"
    assert guest.g.writeCount == 0
    assert guest.g.logs[len(guest.g.logs)] == "[midijamrange] Play Together radius: 4200."
    guest.g.Game.Client = None
    guest.g.runHooks("think")
    assert guest.g.MidiMod.JamRange == 1700


def test_dedicated_console_and_save_failure_still_synchronize():
    server = GroupEnv(server=True, saved=2000)
    server.g.Game.Server.OwnerConnection = None
    server.command(5000)
    assert server.g.files[CONFIG_PATH] == "5000\n"
    server.g.failSave = True
    server.command(3000)
    assert server.g.MidiMod.JamRange == 3000
    assert server.g.files[CONFIG_PATH] == "5000\n"
    assert server.messages("MidiMod.JamRange.State")[-1].message.data[1] == 3000


def test_localized_group_command_and_buttons_have_matching_keys():
    english = ET.parse(ROOT / "Texts/English.xml").getroot()
    russian = ET.parse(ROOT / "Texts/Russian.xml").getroot()
    assert {entry.tag.lower() for entry in english} == {entry.tag.lower() for entry in russian}
    for key in ("help", "current", "changed", "invalid", "hostonly", "waiting", "savefailed", "left", "outofrange"):
        assert russian.find("midijamrange." + key) is not None
    assert russian.find("midiplayer.jamtitle").text == "Играть вместе:"
    assert english.find("midiplayer.jamtitle").text == "Play Together:"
