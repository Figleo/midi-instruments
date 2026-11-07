using System.Reflection;
using Barotrauma.LuaCs.Data;
using HarmonyLib;
using MidiInstruments.Compatibility;

internal static partial class Program
{
    private static string ApplyPreferences(bool multiplayer = false, bool canUpload = false)
        => SpwSoundPreferences.ApplyToManager(typeof(PreferenceManager), multiplayer, canUpload);

    private static void RunPreferenceChecks()
    {
        Check(SpwSoundPreferences.Apply() == "midispw.unavailable", "Without SPW, clicking has no configuration side effects");
        foreach (string existing in new[] { null, "notes", "NOTES", "Notes" })
        foreach (bool inXml in new[] { false, true })
        {
            PreferenceManager.Reset();
            var original = PreferenceManager.LocalConfig;
            if (existing != null)
                (inXml ? original.XMLIgnoredSounds : original.ReverbForcedSounds).Add(existing);
            string result = ApplyPreferences();
            var changed = PreferenceManager.LocalConfig;
            Check(result == "midispw.changed", "Fill missing lists");
            Check(changed.XMLIgnoredSounds.Count(s => s.Equals("notes", StringComparison.OrdinalIgnoreCase)) == 1,
                "One XML entry, case insensitive");
            Check(changed.ReverbForcedSounds.Count(s => s.Equals("notes", StringComparison.OrdinalIgnoreCase)) == 1,
                "One reverb entry, case insensitive");
            Check(changed.XMLIgnoredSounds.Contains("local-xml") && changed.ReverbForcedSounds.Contains("local-reverb"),
                "Keep existing entries");
            Check(changed.OtherValue == original.OtherValue && changed.SyncSettings == original.SyncSettings
                && changed.PitchIgnoredSounds.SetEquals(original.PitchIgnoredSounds), "Preserve unrelated preferences");
            Check(ReferenceEquals(changed.EavesdroppingKeyOrMouse, original.EavesdroppingKeyOrMouse), "Preserve parsed binding");
            Check(PreferenceManager.Saved.XMLIgnoredSounds.SetEquals(changed.XMLIgnoredSounds)
                && PreferenceManager.Saved.ReverbForcedSounds.SetEquals(changed.ReverbForcedSounds), "Persist both lists");
            Check(PreferenceManager.Updates == 1 && ReferenceEquals(PreferenceManager.OldConfig, original), "SPW updates with old/new objects");
            Check(ApplyPreferences() == "midispw.unchanged", "Repeated click reports already configured");
            Check(PreferenceManager.Saves == 1 && PreferenceManager.Updates == 1, "Repeated click does not save or refresh again");
        }

        PreferenceManager.Reset();
        PreferenceManager.LocalConfig.XMLIgnoredSounds.Add("Notes");
        PreferenceManager.LocalConfig.ReverbForcedSounds.Add("NOTES");
        Check(ApplyPreferences() == "midispw.unchanged" && PreferenceManager.Saves == 0, "Both lists already configured");
        PreferenceManager.LocalConfig.XMLIgnoredSounds.Remove("Notes");
        Check(ApplyPreferences() == "midispw.changed", "User removal is restored only on the next click");

        PreferenceManager.Reset();
        var beforeFailure = PreferenceManager.LocalConfig;
        PreferenceManager.FailSave = true;
        bool failed = false;
        try { ApplyPreferences(); } catch (TargetInvocationException) { failed = true; }
        Check(failed && ReferenceEquals(beforeFailure, PreferenceManager.LocalConfig), "Failed write leaves live config untouched");
        Check(!beforeFailure.XMLIgnoredSounds.Contains("notes") && PreferenceManager.Updates == 0, "Failed write never applies lists");

        PreferenceManager.Reset();
        PreferenceManager.LocalConfig.ReverbForcedSounds = null;
        failed = false;
        try { ApplyPreferences(); } catch (InvalidOperationException) { failed = true; }
        Check(failed && PreferenceManager.Saves == 0, "Malformed list rejected before writing");
        Check(!PreferenceManager.LocalConfig.XMLIgnoredSounds.Contains("notes"), "Validation never changes original list");

        PreferenceManager.Reset();
        Check(ApplyPreferences(true, true) == "midispw.uploaded", "Host with sync enabled uploads through SPW");
        Check(PreferenceManager.Uploads == 1 && PreferenceManager.Updates == 1 && PreferenceManager.ManualUpload,
            "Use manual upload and local SPW refresh");
        PreferenceManager.Reset();
        PreferenceManager.LocalConfig.SyncSettings = false;
        Check(ApplyPreferences(true, true) == "midispw.changed" && PreferenceManager.Uploads == 0,
            "Respect local synchronization disabled");

        PreferenceManager.Reset();
        var remote = PreferenceManager.ServerConfig = PreferenceConfig.Remote();
        Check(ApplyPreferences(true, false) == "midispw.serveroverride", "Guest learns about active server override");
        Check(PreferenceManager.Saves == 1 && PreferenceManager.Uploads == 0 && PreferenceManager.Updates == 0,
            "Guest saves locally without changing active server settings");
        Check(ReferenceEquals(PreferenceManager.ServerConfig, remote) && !remote.XMLIgnoredSounds.Contains("notes"),
            "Guest does not mutate server config");

        PreferenceManager.Reset();
        remote = PreferenceManager.ServerConfig = PreferenceConfig.Remote();
        Check(ApplyPreferences(true, true) == "midispw.uploaded", "Host merges the active server lists");
        var uploaded = PreferenceManager.Uploaded;
        Check(uploaded.OtherValue == remote.OtherValue
            && uploaded.XMLIgnoredSounds.Contains("remote-xml") && uploaded.ReverbForcedSounds.Contains("remote-reverb"),
            "Upload preserves active server preferences");
        Check(uploaded.XMLIgnoredSounds.Contains("notes") && uploaded.ReverbForcedSounds.Contains("notes"), "Upload adds both keywords");
        Check(PreferenceManager.LocalConfig.OtherValue == "local" && PreferenceManager.LocalConfig.XMLIgnoredSounds.Contains("local-xml"),
            "Temporary upload config never replaces saved local preferences");
        Check(!remote.XMLIgnoredSounds.Contains("notes") && PreferenceManager.Updates == 0,
            "Server-owned live config waits for SPW acknowledgement");
        PreferenceManager.ServerConfig = uploaded;
        Check(ApplyPreferences(true, true) == "midispw.unchanged" && PreferenceManager.Uploads == 1,
            "After sync, repeated click does not upload again");

        PreferenceManager.Reset();
        PreferenceManager.ServerConfig = PreferenceConfig.Remote();
        PreferenceManager.LocalConfig.XMLIgnoredSounds.Add("notes");
        PreferenceManager.LocalConfig.ReverbForcedSounds.Add("notes");
        PreferenceManager.FailUpload = true;
        var savedLocal = PreferenceManager.LocalConfig;
        failed = false;
        try { ApplyPreferences(true, true); } catch (TargetInvocationException) { failed = true; }
        Check(failed && ReferenceEquals(PreferenceManager.LocalConfig, savedLocal), "Upload failure restores local object in finally");

        string directory = Path.GetFullPath("test-mod");
        SpwDistancePitch.ConfigureModDirectory(directory);
        Check(SpwSettingsButton.IsButtonSetting("SpwPatch", directory.ToUpperInvariant()), "Recognize our action setting");
        Check(!SpwSettingsButton.IsButtonSetting("SpwPatch", directory + "-other"), "Do not replace another mod's setting");
        Check(!SpwSettingsButton.IsButtonSetting("MidiVolume", directory), "Do not replace volume control");
        Check(!SpwSettingsButton.IsButtonSetting("SpwPatch", null), "Ignore missing package");
        MethodInfo display = AccessTools.Method(typeof(SettingEntry<string>), "AddDisplayComponent");
        SpwSettingsButton.Install();
        SpwSettingsButton.Install();
        Check(Harmony.GetPatchInfo(display).Prefixes.Count(p => p.owner == "MidiInstruments.SpwSettingsButton") == 1,
            "Button renderer installs once on actual LuaCs API");
        SpwSettingsButton.Remove();
        Check(Harmony.GetPatchInfo(display) == null || !Harmony.GetPatchInfo(display).Prefixes.Any(p => p.owner == "MidiInstruments.SpwSettingsButton"),
            "Button renderer unloads");
    }

    private static void VerifyInstalledPreferencesApi(Assembly assembly)
    {
        // Inspect metadata without initializing the real ConfigManager or writing the player's config.
        Type manager = assembly.GetType("SoundproofWalls.ConfigManager", true);
        Type config = assembly.GetType("SoundproofWalls.Config", true);
        Check(manager.GetField("LocalConfig").FieldType == config, "Actual SPW exposes local configuration");
        Check(manager.GetProperty("ServerConfig").PropertyType == config, "Actual SPW exposes server configuration");
        foreach (string list in new[] { "XMLIgnoredSounds", "ReverbForcedSounds" })
            Check(config.GetProperty(list).PropertyType == typeof(HashSet<string>), "Actual SPW list: " + list);
        foreach (var spec in new[] {
            ("CloneConfig", new[] { config }), ("SaveConfig", new[] { config }),
            ("UpdateConfig", new[] { config, config, typeof(bool), typeof(bool), typeof(byte) }),
            ("UploadClientConfigToServer", new[] { typeof(bool) })
        })
            Check(manager.GetMethod(spec.Item1, spec.Item2) != null, "Actual SPW API: " + spec.Item1);
    }
}

internal sealed class PreferenceConfig
{
    public HashSet<string> XMLIgnoredSounds { get; set; } = new() { "local-xml" };
    public HashSet<string> ReverbForcedSounds { get; set; } = new() { "local-reverb" };
    public HashSet<string> PitchIgnoredSounds { get; set; } = new() { "unrelated-pitch" };
    public bool SyncSettings { get; set; } = true;
    public string OtherValue { get; set; } = "local";
    public object EavesdroppingKeyOrMouse { get; set; } = new();
    public static PreferenceConfig Remote() => new()
    {
        XMLIgnoredSounds = new() { "remote-xml" }, ReverbForcedSounds = new() { "remote-reverb" }, OtherValue = "remote"
    };
}

internal static class PreferenceManager
{
    public static PreferenceConfig LocalConfig;
    public static PreferenceConfig ServerConfig { get; set; }
    internal static PreferenceConfig Saved, Uploaded, OldConfig;
    internal static int Saves, Updates, Uploads;
    internal static bool FailSave, FailUpload, ManualUpload;

    internal static void Reset()
    {
        LocalConfig = new();
        ServerConfig = Saved = Uploaded = OldConfig = null;
        Saves = Updates = Uploads = 0;
        FailSave = FailUpload = ManualUpload = false;
    }

    public static PreferenceConfig CloneConfig(PreferenceConfig config) => new()
    {
        XMLIgnoredSounds = config.XMLIgnoredSounds != null ? new(config.XMLIgnoredSounds) : null,
        ReverbForcedSounds = config.ReverbForcedSounds != null ? new(config.ReverbForcedSounds) : null,
        PitchIgnoredSounds = new(config.PitchIgnoredSounds), SyncSettings = config.SyncSettings, OtherValue = config.OtherValue
    };

    public static void SaveConfig(PreferenceConfig config)
    {
        if (FailSave) throw new IOException("Test write failure");
        Saved = CloneConfig(config);
        Saves++;
    }

    public static void UpdateConfig(PreferenceConfig config, PreferenceConfig old, bool server, bool manual, byte sender)
    {
        OldConfig = old;
        ServerConfig = server ? config : null;
        Updates++;
    }

    public static void UploadClientConfigToServer(bool manual)
    {
        if (FailUpload) throw new IOException("Test upload failure");
        Uploaded = CloneConfig(LocalConfig);
        ManualUpload = manual;
        Uploads++;
    }
}
