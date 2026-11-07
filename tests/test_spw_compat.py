"""Verify client-only patch resources and Lua initialization retries."""
from pathlib import Path
import xml.etree.ElementTree as ET

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = """
CLIENT = true
now, attempts, unavailable = 0, 0, false
os.clock = function() return now end
logs, hooks = {}, {}
MidiMod = { BasePath = '/mods/our-midi/', Log = function(text) logs[#logs + 1] = text end }
Hook = {
    Add = function(_, name, callback) hooks[name] = callback end,
    Remove = function(_, name) hooks[name] = nil end
}
compat = {
    Status = 'Applied',
    ConfigureModDirectory = function(path) configuredPath = path end,
    TryInstallPatch = function() attempts = attempts + 1 end
}
LuaUserData = {
    RegisterType = function(name)
        registeredName = name
        if unavailable then error('assembly not loaded') end
    end,
    CreateStatic = function() return compat end
}
"""


def environment(*, status="Applied", unavailable=False, client=True):
    lua = LuaRuntime()
    lua.execute(BOOTSTRAP)
    globals_ = lua.globals()
    globals_.CLIENT = client
    globals_.unavailable = unavailable
    globals_.compat.Status = status
    lua.execute((ROOT / "Lua/spw_compat.lua").read_text(encoding="utf-8"))
    return lua, globals_


def test_success_configures_exact_mod_path_and_stops_retrying():
    _, g = environment()
    assert g.configuredPath == "/mods/our-midi/"
    assert g.registeredName == "MidiInstruments.Compatibility.SpwDistancePitch"
    assert len(g.logs) == 1
    assert g.logs[1] == "[SPW compatibility] Applied"
    assert g.hooks["MidiMod.SpwCompatibility.Load"] is None


def test_server_does_not_register_types_or_install_patch():
    _, g = environment(client=False)
    assert g.attempts == 0
    assert len(g.logs) == 0
    assert g.configuredPath is None


def test_late_assembly_load_is_retried():
    _, g = environment(unavailable=True)
    callback = g.hooks["MidiMod.SpwCompatibility.Load"]
    assert callback is not None
    g.unavailable = False
    g.now = 2
    callback()
    assert g.attempts == 1
    assert g.hooks["MidiMod.SpwCompatibility.Load"] is None
    assert g.logs[2] == "[SPW compatibility] Applied"


def test_spw_loaded_later_gets_patch_without_repeated_logs():
    _, g = environment(status="Soundproof Walls is not loaded")
    callback = g.hooks["MidiMod.SpwCompatibility.Load"]
    g.now = 2
    callback()
    assert len(g.logs) == 1
    g.compat.Status = "Applied"
    g.now = 4
    callback()
    assert len(g.logs) == 2
    assert g.hooks["MidiMod.SpwCompatibility.Load"] is None


def test_incompatible_version_reports_once_and_stops():
    _, g = environment(status="Incompatible SPW: getter changed")
    assert g.hooks["MidiMod.SpwCompatibility.Load"] is None
    assert g.logs[1] == "[SPW compatibility] Incompatible SPW: getter changed"


def test_patch_resource_is_client_only_and_compiled_from_source():
    config = ET.parse(ROOT / "ModConfig.xml").getroot()
    assemblies = config.findall("Assembly")
    assert len(assemblies) == 1
    assembly = assemblies[0]
    assert assembly.get("Target") == "Client"
    assert assembly.get("IsScript") == "true"
    assert (ROOT / assembly.get("File").replace("%ModDir%/", "")).is_file()
