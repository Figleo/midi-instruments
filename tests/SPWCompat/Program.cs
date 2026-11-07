using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;
using HarmonyLib;
using MidiInstruments.Compatibility;

internal static partial class Program
{
    private static int checks;
    private static int otherPatchCalls;

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
        checks++;
    }

    private static void OtherPatch() { otherPatchCalls++; }

    private static void Main(string[] args)
    {
        string gameDirectory = Path.GetFullPath(args[0]);
        AssemblyLoadContext.Default.Resolving += (_, name) =>
        {
            string path = Path.Combine(gameDirectory, name.Name + ".dll");
            return File.Exists(path) ? AssemblyLoadContext.Default.LoadFromAssemblyPath(path) : null;
        };
        RunPreferenceChecks();
        RunBehaviorChecks();
        if (args.Length > 1) RunInstalledSpwChecks(Path.GetFullPath(args[1]));
        Console.WriteLine("SPW compatibility: " + checks + " checks passed.");
    }

    private static void RunBehaviorChecks()
    {
        string root = Path.GetFullPath("test-mod");
        SpwDistancePitch.ConfigureModDirectory(root);
        string[] banks = {
            "accordion", "guitar", "guitarelectric", "guitarelectric_lead",
            "guitarelectric_crunch", "guitarelectric_bass", "guitar_acoustic",
            "guitar_acoustic_soft", "harmonica"
        };
        foreach (string bank in banks)
        {
            string file = Path.Combine(root, "Sounds", bank + "_notes", bank + "_Cs4.ogg");
            Check(SpwDistancePitch.IsMidiSample(file), "Recognize " + bank);
            Check(!SpwDistancePitch.ShouldApplyDistancePitch(true, file), "Exclude MIDI distance pitch");
            Check(SpwDistancePitch.IsMidiSample(file.Replace('/', '\\').ToUpperInvariant()), "Normalize path");
            Check(!SpwDistancePitch.IsMidiSample(Path.Combine(root + "-other", "Sounds", bank + "_notes", bank + "_C4.ogg")),
                "Do not match another mod with the same samples");
        }
        Check(!SpwDistancePitch.IsMidiSample(Path.Combine(root, "Sounds", "guitar_notes", "other_C4.ogg")), "Validate sample name");
        Check(!SpwDistancePitch.IsMidiSample(Path.Combine(root, "Sounds", "unknown_notes", "unknown_C4.ogg")), "Validate bank");
        Check(SpwDistancePitch.ShouldApplyDistancePitch(true, null), "Null filename preserves SPW setting");
        Check(!SpwDistancePitch.ShouldApplyDistancePitch(false, "other.ogg"), "Respect disabled setting");

        MethodInfo target = typeof(SoundproofWalls.ChannelInfo).GetMethod("UpdatePitch", BindingFlags.Instance | BindingFlags.NonPublic);
        List<CodeInstruction> original = PatchProcessor.GetOriginalInstructions(target).ToList();
        List<CodeInstruction> changed = SpwDistancePitch.Transpile(original, target).ToList();
        Check(changed.Count == original.Count + 3, "Insert only three instructions");
        Check(changed.Where(instruction => original.Contains(instruction)).SequenceEqual(original), "Preserve every original instruction in order");
        Check(changed.Count(instruction => instruction.operand is MethodInfo method && method.Name == "ShouldApplyDistancePitch") == 1,
            "Insert exactly one distance filter");
        foreach (List<CodeInstruction> bad in new[] {
            new List<CodeInstruction> { new CodeInstruction(OpCodes.Ret) },
            original.Concat(original).ToList()
        })
        {
            bool rejected = false;
            try { SpwDistancePitch.Transpile(bad, target).ToList(); }
            catch (InvalidOperationException) { rejected = true; }
            Check(rejected, "Reject missing or duplicate getter");
        }

        Harmony otherPatcher = new Harmony("SPWCompat.Tests.OtherOwner");
        otherPatcher.Patch(target, prefix: new HarmonyMethod(typeof(Program).GetMethod(nameof(OtherPatch), BindingFlags.Static | BindingFlags.NonPublic)));
        Check(SpwDistancePitch.TryInstallPatch(), "Install compatibility patch");
        Check(SpwDistancePitch.TryInstallPatch(), "Install is idempotent");
        Check(Harmony.GetPatchInfo(target).Transpilers.Count(patch => patch.owner == "MidiInstruments.SpwDistancePitch") == 1,
            "Do not register twice");

        SoundproofWalls.Config config = SoundproofWalls.Config.Current;
        string midi = Path.Combine(root, "Sounds", "guitar_notes", "guitar_C4.ogg");
        foreach (float startPitch in new[] { 0.5f, 1f, 2f })
        foreach (float distance in new[] { 0f, 400f, 900f })
        foreach (float muffle in new[] { 0f, 0.5f, 1f })
        foreach (float otherModifier in new[] { 0f, -0.2f, 0.1f })
        {
            var sample = new SoundproofWalls.ChannelInfo(midi, startPitch, distance, muffle, otherModifier);
            config.PitchWithDistance = false;
            sample.Run();
            float expected = sample.Pitch;
            config.PitchWithDistance = true;
            sample.Run();
            Check(Math.Abs(expected - sample.Pitch) < 0.00001f, "MIDI result equals SPW with only distance disabled");
            Check(config.PitchWithDistance, "Never toggle the global setting");

            var other = new SoundproofWalls.ChannelInfo("other.ogg", startPitch, distance, muffle, otherModifier);
            other.Run();
            float otherExpected = startPitch * (1f + otherModifier - muffle * distance / 1000f);
            Check(Math.Abs(other.Pitch - otherExpected) < 0.00001f, "Other sound retains distance calculation");
        }
        Check(otherPatchCalls > 0, "Keep another owner's patch working");
        SpwDistancePitch.RemovePatch();
        Check(Harmony.GetPatchInfo(target).Prefixes.Any(patch => patch.owner == "SPWCompat.Tests.OtherOwner"),
            "Unloading leaves another owner's patch installed");
        config.PitchWithDistance = true;
        var restored = new SoundproofWalls.ChannelInfo(midi, 2f, 900f, 1f, 0f);
        restored.Run();
        Check(Math.Abs(restored.Pitch - 0.2f) < 0.00001f, "Unloading restores original behavior");
        otherPatcher.UnpatchSelf();
    }

    private static void RunInstalledSpwChecks(string spwFile)
    {
        // Validate the installed DLL without starting audio or SPW's file services.
        Assembly assembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(spwFile);
        Type type = assembly.GetType("SoundproofWalls.ChannelInfo", true);
        VerifyInstalledPreferencesApi(assembly);
        MethodInfo target = type.GetMethod("UpdatePitch", BindingFlags.Instance | BindingFlags.NonPublic);
        List<CodeInstruction> original = PatchProcessor.GetOriginalInstructions(target).ToList();
        List<CodeInstruction> changed = SpwDistancePitch.Transpile(original, target).ToList();
        Check(changed.Count == original.Count + 3, "Installed SPW has the supported getter layout");
        Check(changed.Where(instruction => original.Contains(instruction)).SequenceEqual(original), "Installed SPW calculations remain intact");
        Check(SpwDistancePitch.TryInstallPatch(), "Harmony installs on the actual SPW method: " + SpwDistancePitch.Status);
        Check(Harmony.GetPatchInfo(target).Transpilers.Any(patch => patch.owner == "MidiInstruments.SpwDistancePitch"),
            "Actual SPW method is patched");
        SpwDistancePitch.RemovePatch();
        Check(Harmony.GetPatchInfo(target) == null || !Harmony.GetPatchInfo(target).Transpilers.Any(patch => patch.owner == "MidiInstruments.SpwDistancePitch"),
            "Actual SPW patch unloads");
        Console.WriteLine("Installed SPW method verified; no game audio was invoked.");
    }
}

// Independent method model for transpiler behavior tests; the installed SPW method is checked separately.
namespace SoundproofWalls
{
    public sealed class Config
    {
        public static readonly Config Current = new Config();
        public bool PitchWithDistance { [MethodImpl(MethodImplOptions.NoInlining)] get; set; }
    }

    public sealed class ChannelInfo
    {
        public string LongName;
        public float Pitch;
        private readonly float startPitch, distance, muffle, otherModifier;

        public ChannelInfo(string filename, float pitch, float distance, float muffle, float otherModifier)
        {
            LongName = filename;
            startPitch = pitch;
            this.distance = distance;
            this.muffle = muffle;
            this.otherModifier = otherModifier;
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private void UpdatePitch()
        {
            float modifier = 1f + otherModifier;
            if (Config.Current.PitchWithDistance)
                modifier -= muffle * distance / 1000f;
            Pitch = startPitch * modifier;
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        public void Run() { UpdatePitch(); }
    }
}
