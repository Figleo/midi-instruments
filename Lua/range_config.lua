MidiMod = MidiMod or {}
MidiMod.RangeConfig = require("range_settings").create({
    command = "midirange",
    label = "Instrument sound range",
    field = "SoundRange",
    defaultRange = 1000,
    network = "MidiMod.Range",
    fileName = "MidiInstruments_Range.txt",
})
