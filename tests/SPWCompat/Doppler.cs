using Barotrauma.Sounds;
using HarmonyLib;
using MidiInstruments.Compatibility;
using OpenAL;

internal static partial class Program
{
    private static void RunDopplerChecks()
    {
        var factors = new Dictionary<uint, float> { [10] = 0.7f, [20] = 1f, [30] = 0.3f };
        int reads = 0, writes = 0;
        float Read(uint source) { reads++; return factors[source]; }
        void Write(uint source, float value) { writes++; factors[source] = value; }

        Check(Al.EnumDopplerFactor == 0xC000, "Use OpenAL's per-source doppler parameter");
        SpwDoppler.ApplyToSource(0, true, Read, Write);
        SpwDoppler.ApplyToSource(20, false, Read, Write);
        Check(reads == 0 && writes == 0, "Unavailable and unrelated sources need no OpenAL calls");
        SpwDoppler.ApplyToSource(10, true, Read, Write);
        Check(factors[10] == 0f && factors[20] == 1f, "Disable doppler only on the MIDI source");
        SpwDoppler.ApplyToSource(10, true, Read, Write);
        Check(reads == 1 && writes == 1, "Repeated assignment preserves the original factor");
        SpwDoppler.ApplyToSource(10, false, Read, Write);
        Check(factors[10] == 0.7f, "Disposal or reuse restores the actual previous factor");
        SpwDoppler.ApplyToSource(10, false, Read, Write);
        Check(writes == 2, "Restoration happens once");

        SpwDoppler.ApplyToSource(10, true, Read, Write);
        SpwDoppler.ApplyToSource(30, true, Read, Write);
        SpwDoppler.RestoreSources(Write);
        Check(factors[10] == 0.7f && factors[30] == 0.3f, "Unload restores every still-active MIDI source");
        int before = writes;
        SpwDoppler.RestoreSources(Write);
        Check(writes == before, "Unload clears ownership of restored sources");

        bool failed = false;
        try { SpwDoppler.ApplyToSource(10, true, _ => throw new InvalidOperationException("test read error"), Write); }
        catch (InvalidOperationException) { failed = true; }
        Check(failed && writes == before, "Unsupported source getter never changes the source");
        failed = false;
        try { SpwDoppler.ApplyToSource(10, true, Read, (_, __) => throw new InvalidOperationException("test write error")); }
        catch (InvalidOperationException) { failed = true; }
        Check(failed && factors[10] == 0.7f, "Failed write leaves the source alone");
        SpwDoppler.RestoreSources(Write);
        Check(writes == before, "Failed write is not tracked as an applied exclusion");

        var assign = AccessTools.Method(typeof(SoundManager), "AssignFreeSourceToChannel", new[] { typeof(SoundChannel) });
        var dispose = AccessTools.Method(typeof(SoundChannel), "Dispose", Type.EmptyTypes);
        Check(assign != null && assign.ReturnType == typeof(int), "Actual game exposes the source allocation hook");
        SpwDoppler.Install();
        SpwDoppler.Install();
        Check(Harmony.GetPatchInfo(assign).Postfixes.Count(p => p.owner == "MidiInstruments.SpwDoppler") == 1,
            "Source is configured once, before SoundChannel starts playback");
        Check(Harmony.GetPatchInfo(dispose).Prefixes.Count(p => p.owner == "MidiInstruments.SpwDoppler") == 1,
            "Source restores on actual game disposal");
        SpwDoppler.Remove();
        Check(Harmony.GetPatchInfo(assign) == null || !Harmony.GetPatchInfo(assign).Postfixes.Any(p => p.owner == "MidiInstruments.SpwDoppler"),
            "Unload removes the allocation hook");
        Check(Harmony.GetPatchInfo(dispose) == null || !Harmony.GetPatchInfo(dispose).Prefixes.Any(p => p.owner == "MidiInstruments.SpwDoppler"),
            "Unload removes the disposal hook");
    }
}
