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
        public void Initialize() { SpwSettingsButton.Install(); }
        public void OnLoadCompleted() { SpwDistancePitch.TryInstallPatch(); }
        public void Dispose()
        {
            SpwSettingsButton.Remove();
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
                SpwDoppler.Install();
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
            SpwDoppler.Remove();
            Patcher.UnpatchSelf();
            patchedMethod = null;
            soundRoot = null;
            ModDirectory = null;
            Status = "Unloaded";
        }
    }

    // OpenAL's per-source doppler factor excludes both source and listener motion.
    // Pooled sources retain their previous factor when the channel is released or reused.
    internal static class SpwDoppler
    {
        private static readonly Harmony Patcher = new Harmony("MidiInstruments.SpwDoppler");
        private static readonly Dictionary<uint, float> OriginalFactors = new Dictionary<uint, float>();
        private static readonly object Sync = new object();
        private static bool installed;
        private static bool reportedError;

        internal static void Install()
        {
            if (installed) return;
            try
            {
                Patcher.Patch(AccessTools.Method(typeof(SoundManager), "AssignFreeSourceToChannel", new[] { typeof(SoundChannel) }),
                    postfix: new HarmonyMethod(typeof(SpwDoppler), nameof(SourceAssigned)));
                Patcher.Patch(AccessTools.Method(typeof(SoundChannel), "Dispose", Type.EmptyTypes),
                    prefix: new HarmonyMethod(typeof(SpwDoppler), nameof(SourceDisposing)));
                installed = true;
            }
            catch { Patcher.UnpatchSelf(); throw; }
        }

        private static void SourceAssigned(SoundManager __instance, SoundChannel newChannel, int __result)
        {
            if (__result < 0 || newChannel.Sound == null) return;
            uint source = __instance.GetSourceFromIndex(newChannel.Sound.SourcePoolIndex, __result);
            ConfigureSource(source, SpwDistancePitch.IsMidiSample(newChannel.Sound.Filename));
        }

        private static void SourceDisposing(SoundChannel __instance)
        {
            if (__instance.mutex == null) return;
            lock (__instance.mutex)
            {
                if (__instance.ALSourceIndex < 0 || __instance.Sound == null) return;
                uint source = __instance.Sound.Owner.GetSourceFromIndex(__instance.Sound.SourcePoolIndex, __instance.ALSourceIndex);
                ConfigureSource(source, false);
            }
        }

        private static void ConfigureSource(uint source, bool midi)
        {
            try { ApplyToSource(source, midi, ReadFactor, WriteFactor); }
            catch (Exception error)
            {
                if (reportedError) return;
                reportedError = true;
                DebugConsole.ThrowError("[MidiMod] Doppler exclusion: " + error.GetBaseException().Message);
            }
        }

        private static float ReadFactor(uint source)
        {
            Al.GetError();
            Al.GetSourcef(source, Al.EnumDopplerFactor, out float factor);
            int error = Al.GetError();
            if (error != 0) throw new InvalidOperationException("Reading source doppler: " + Al.GetErrorString(error));
            return factor;
        }

        private static void WriteFactor(uint source, float factor)
        {
            Al.GetError();
            Al.Sourcef(source, Al.EnumDopplerFactor, factor);
            int error = Al.GetError();
            if (error != 0) throw new InvalidOperationException("Setting source doppler: " + Al.GetErrorString(error));
        }

        internal static void ApplyToSource(uint source, bool midi, Func<uint, float> read, Action<uint, float> write)
        {
            if (source == 0) return;
            lock (Sync)
            {
                if (midi)
                {
                    if (OriginalFactors.ContainsKey(source)) return;
                    float original = read(source);
                    write(source, 0f);
                    OriginalFactors.Add(source, original);
                }
                else if (OriginalFactors.TryGetValue(source, out float original))
                {
                    write(source, original);
                    OriginalFactors.Remove(source);
                }
            }
        }

        internal static void RestoreSources(Action<uint, float> write)
        {
            lock (Sync)
            {
                foreach (var entry in OriginalFactors.ToArray())
                {
                    write(entry.Key, entry.Value);
                    OriginalFactors.Remove(entry.Key);
                }
            }
        }

        internal static void Remove()
        {
            RestoreSources((source, factor) =>
            {
                // The audio context may already be closed during a full game reload.
                try { if (Al.IsSource(source)) WriteFactor(source, factor); }
                catch (Exception error) { DebugConsole.ThrowError("[MidiMod] Restoring doppler: " + error.Message); }
            });
            Patcher.UnpatchSelf();
            installed = false;
            reportedError = false;
        }
    }

    // Adding notes is a user action; startup leaves manually edited lists alone.
    public static class SpwSoundPreferences
    {
        private static readonly string[] Lists = { "XMLIgnoredSounds", "ReverbForcedSounds" };

        public static string Apply()
        {
            Type manager = AppDomain.CurrentDomain.GetAssemblies()
                .Select(assembly => assembly.GetType("SoundproofWalls.ConfigManager", false))
                .LastOrDefault(type => type != null);
            if (manager == null) return "midispw.unavailable";
            bool multiplayer = GameMain.IsMultiplayer;
            Client myClient = GameMain.Client?.MyClient;
            bool canUpload = multiplayer && myClient != null
                && (myClient.IsOwner || myClient.HasPermission(ClientPermissions.ManageSettings));
            return ApplyToManager(manager, multiplayer, canUpload);
        }

        // Use SPW's public API so saving, sound metadata updates and synchronization follow its menu.
        internal static string ApplyToManager(Type manager, bool multiplayer, bool canUpload)
        {
            const BindingFlags flags = BindingFlags.Public | BindingFlags.Static;
            FieldInfo localField = manager.GetField("LocalConfig", flags)
                ?? throw new InvalidOperationException("SPW LocalConfig is unavailable");
            Type configType = localField.FieldType;
            PropertyInfo serverProperty = manager.GetProperty("ServerConfig", flags)
                ?? throw new InvalidOperationException("SPW ServerConfig is unavailable");
            MethodInfo clone = RequireMethod(manager, "CloneConfig", configType);
            MethodInfo save = RequireMethod(manager, "SaveConfig", configType);
            MethodInfo update = RequireMethod(manager, "UpdateConfig", configType, configType, typeof(bool), typeof(bool), typeof(byte));
            MethodInfo upload = RequireMethod(manager, "UploadClientConfigToServer", typeof(bool));
            object local = localField.GetValue(null)
                ?? throw new InvalidOperationException("SPW local configuration is unavailable");
            object server = serverProperty.GetValue(null);
            object nextLocal = clone.Invoke(null, new[] { local });
            // SPW's JSON clone omits the parsed keyboard or mouse binding.
            PropertyInfo binding = configType.GetProperty("EavesdroppingKeyOrMouse");
            if (binding != null && binding.CanRead && binding.CanWrite)
                binding.SetValue(nextLocal, binding.GetValue(local));
            bool localChanged = AddNotes(nextLocal);
            object nextServer = server != null ? clone.Invoke(null, new[] { server }) : null;
            bool serverChanged = nextServer != null && AddNotes(nextServer);

            // Save before replacing the active config so write errors leave the live settings intact.
            if (localChanged)
            {
                save.Invoke(null, new[] { nextLocal });
                localField.SetValue(null, nextLocal);
                if (server == null)
                    update.Invoke(null, new object[] { nextLocal, local, false, false, (byte)0 });
            }

            if (multiplayer && canUpload)
            {
                if (server != null && serverChanged)
                {
                    // UploadClientConfigToServer serializes LocalConfig synchronously.
                    // Temporarily use a copy of the active server config, then restore the player's local config.
                    PropertyInfo sync = configType.GetProperty("SyncSettings")
                        ?? throw new InvalidOperationException("SPW SyncSettings is unavailable");
                    sync.SetValue(nextServer, true);
                    object savedLocal = localField.GetValue(null);
                    try
                    {
                        localField.SetValue(null, nextServer);
                        upload.Invoke(null, new object[] { true });
                    }
                    finally { localField.SetValue(null, savedLocal); }
                    return "midispw.uploaded";
                }
                if (server == null && localChanged
                    && configType.GetProperty("SyncSettings")?.GetValue(nextLocal) is bool syncEnabled && syncEnabled)
                {
                    upload.Invoke(null, new object[] { true });
                    return "midispw.uploaded";
                }
            }
            if (serverChanged) return "midispw.serveroverride";
            return localChanged ? "midispw.changed" : "midispw.unchanged";
        }

        private static MethodInfo RequireMethod(Type type, string name, params Type[] arguments)
        {
            return type.GetMethod(name, BindingFlags.Public | BindingFlags.Static, null, arguments, null)
                ?? throw new InvalidOperationException("SPW " + name + " API is unavailable");
        }

        internal static bool AddNotes(object config)
        {
            // Validate both lists before changing either one to avoid partial updates.
            HashSet<string>[] sets = Lists.Select(name =>
                config.GetType().GetProperty(name)?.GetValue(config) as HashSet<string>
                ?? throw new InvalidOperationException("SPW " + name + " list is unavailable")).ToArray();
            bool changed = false;
            foreach (HashSet<string> sounds in sets)
            {
                if (sounds.Any(sound => string.Equals(sound, "notes", StringComparison.OrdinalIgnoreCase))) continue;
                changed |= sounds.Add("notes");
            }
            return changed;
        }
    }

    internal static class SpwSettingsButton
    {
        private static readonly Harmony Patcher = new Harmony("MidiInstruments.SpwSettingsButton");
        private static bool installed;

        internal static void Install()
        {
            if (installed) return;
            Patcher.Patch(AccessTools.Method(typeof(SettingEntry<string>), "AddDisplayComponent"),
                prefix: new HarmonyMethod(typeof(SpwSettingsButton), nameof(AddButton)));
            installed = true;
        }

        internal static bool IsButtonSetting(string name, string packageDirectory)
        {
            return name == "SpwPatch" && SpwDistancePitch.ModDirectory != null
                && !string.IsNullOrEmpty(packageDirectory)
                && string.Equals(Path.GetFullPath(packageDirectory).TrimEnd('/', '\\'),
                    SpwDistancePitch.ModDirectory, StringComparison.OrdinalIgnoreCase);
        }

        private static bool AddButton(SettingEntry<string> __instance, GUILayoutGroup layoutGroup, Vector2 relativeSize)
        {
            if (!IsButtonSetting(__instance.InternalName, __instance.OwnerPackage?.Dir)) return true;
            new GUIButton(new RectTransform(relativeSize, layoutGroup.RectTransform), TextManager.Get("midispw.button"))
            {
                ToolTip = TextManager.Get("midispw.tooltip"),
                OnClicked = (_, __) =>
                {
                    string result;
                    try { result = SpwSoundPreferences.Apply(); }
                    catch (Exception error)
                    {
                        result = "midispw.failed";
                        DebugConsole.ThrowError("[MidiMod] SPW preferences: " + error.GetBaseException().Message);
                    }
                    var messageBox = new GUIMessageBox(TextManager.Get("midispw.title"), TextManager.Get(result));
                    return true;
                }
            };
            // Button actions bypass the menu's value cache; Apply and Reset must not replay them.
            return false;
        }

        internal static void Remove()
        {
            Patcher.UnpatchSelf();
            installed = false;
        }
    }
}
