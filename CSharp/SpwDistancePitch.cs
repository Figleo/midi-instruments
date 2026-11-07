using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using Barotrauma;
using Barotrauma.LuaCs;
using Barotrauma.LuaCs.Data;
using Barotrauma.Networking;
using Barotrauma.Sounds;
using HarmonyLib;
using Microsoft.Xna.Framework;
using OpenAL;

namespace MidiInstruments.Compatibility
{
    // LuaCs compiles this client-only assembly through ModConfig.xml.
    public sealed class SpwDistancePitchPlugin : IAssemblyPlugin
    {
        public void PreInitPatching() { }
        public void Initialize() { }
        public void OnLoadCompleted() { SpwDistancePitch.TryInstallPatch(); }
        public void Dispose()
        {
            SpwDistancePitch.RemovePatch();
        }
    }

    public static class SpwDistancePitch
    {
        private const string HarmonyId = "MidiInstruments.SpwDistancePitch";
        private static readonly Harmony Patcher = new Harmony(HarmonyId);
        private static readonly HashSet<string> Banks = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "accordion", "guitar", "guitarelectric", "guitarelectric_lead",
            "guitarelectric_crunch", "guitarelectric_bass", "guitar_acoustic",
            "guitar_acoustic_soft", "harmonica"
        };
        private static string soundRoot;
        private static MethodInfo patchedMethod;

        public static string Status { get; private set; } = "Not initialized";
        internal static string ModDirectory { get; private set; }

        // The directory supplied by Lua identifies the enabled mod copy in LocalMods or Workshop.
        public static void ConfigureModDirectory(string modDirectory)
        {
            ModDirectory = Path.GetFullPath(modDirectory).TrimEnd('/', '\\');
            soundRoot = Normalize(Path.GetFullPath(Path.Combine(modDirectory, "Sounds"))).TrimEnd('/') + "/";
        }

        private static string Normalize(string path)
        {
            return path.Replace('\\', '/');
        }

        public static bool IsMidiSample(string filename)
        {
            string root = soundRoot;
            if (root == null || string.IsNullOrEmpty(filename)) return false;
            string path = Normalize(filename);
            if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return false;

            string relative = path.Substring(root.Length);
            int separator = relative.IndexOf('/');
            if (separator < 0) return false;
            string directory = relative.Substring(0, separator);
            if (!directory.EndsWith("_notes", StringComparison.OrdinalIgnoreCase)) return false;
            string bank = directory.Substring(0, directory.Length - "_notes".Length);
            if (!Banks.Contains(bank)) return false;
            string sample = relative.Substring(separator + 1);
            return sample.IndexOf('/') < 0
                && sample.StartsWith(bank + "_", StringComparison.OrdinalIgnoreCase)
                && sample.EndsWith(".ogg", StringComparison.OrdinalIgnoreCase);
        }

        // Filter only the distance-pitch flag; SPW keeps its original pitch calculation.
        public static bool ShouldApplyDistancePitch(bool enabled, string filename)
        {
            return enabled && !IsMidiSample(filename);
        }

        public static bool TryInstallPatch()
        {
            if (patchedMethod != null)
            {
                Status = "Applied";
                return true;
            }
            Type channelInfo = AppDomain.CurrentDomain.GetAssemblies()
                .Select(assembly => assembly.GetType("SoundproofWalls.ChannelInfo", false))
                .LastOrDefault(type => type != null);
            if (channelInfo == null)
            {
                Status = "Soundproof Walls is not loaded";
                return false;
            }
            MethodInfo method = channelInfo.GetMethod("UpdatePitch",
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
                null, Type.EmptyTypes, null);
            if (method == null || method.ReturnType != typeof(void))
            {
                Status = "Incompatible SPW: UpdatePitch was not found";
                return false;
            }
            try
            {
                Patcher.Patch(method, transpiler: new HarmonyMethod(typeof(SpwDistancePitch), nameof(Transpile)));
                patchedMethod = method;
                Status = "Applied";
                return true;
            }
            catch (Exception error)
            {
                // Reject unknown method layouts without removing patches owned by SPW.
                Patcher.Unpatch(method, HarmonyPatchType.Transpiler, HarmonyId);
                Status = "Incompatible SPW: " + error.GetBaseException().Message;
                return false;
            }
        }

        public static IEnumerable<CodeInstruction> Transpile(
            IEnumerable<CodeInstruction> instructions, MethodBase __originalMethod)
        {
            List<CodeInstruction> original = instructions.ToList();
            FieldInfo filename = __originalMethod.DeclaringType.GetField("LongName",
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            if (filename == null || filename.FieldType != typeof(string))
                throw new InvalidOperationException("ChannelInfo.LongName is unavailable");

            int[] matches = original.Select((instruction, index) => new { instruction, index })
                .Where(entry => IsDistancePitchGetter(entry.instruction))
                .Select(entry => entry.index).ToArray();
            if (matches.Length != 1)
                throw new InvalidOperationException("Expected exactly one PitchWithDistance getter, found " + matches.Length);

            // Refine the setting immediately after its getter, leaving SPW's instructions and branches intact.
            List<CodeInstruction> result = new List<CodeInstruction>(original.Count + 3);
            MethodInfo filter = typeof(SpwDistancePitch).GetMethod(nameof(ShouldApplyDistancePitch));
            for (int index = 0; index < original.Count; index++)
            {
                result.Add(original[index]);
                if (index == matches[0])
                {
                    result.Add(new CodeInstruction(OpCodes.Ldarg_0));
                    result.Add(new CodeInstruction(OpCodes.Ldfld, filename));
                    result.Add(new CodeInstruction(OpCodes.Call, filter));
                }
            }
            return result;
        }

        private static bool IsDistancePitchGetter(CodeInstruction instruction)
        {
            MethodInfo method = instruction.operand as MethodInfo;
            return (instruction.opcode == OpCodes.Call || instruction.opcode == OpCodes.Callvirt)
                && method != null && method.DeclaringType.FullName == "SoundproofWalls.Config"
                && method.Name == "get_PitchWithDistance" && method.ReturnType == typeof(bool)
                && method.GetParameters().Length == 0;
        }

        public static void RemovePatch()
        {
            Patcher.UnpatchSelf();
            patchedMethod = null;
            soundRoot = null;
            ModDirectory = null;
            Status = "Unloaded";
        }
    }

}
