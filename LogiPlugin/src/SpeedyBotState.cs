namespace Loupedeck.SpeedyBotPlugin
{
    using System;
    using System.Collections.Generic;
    using System.Diagnostics;
    using System.IO;
    using System.Text.Json;
    using System.Threading;

    /// <summary>What Speedy Bot is doing, as the key shows it.</summary>
    public enum SpeedyMode { NotRunning, Off, On, AutoWaiting, AutoActive }

    /// <summary>
    /// Reads the state file Speedy Bot writes (~/Library/Application Support/Speedy Bot/state.json) once a second,
    /// and sends it speedybot:// links. The app owns its state; this only shows it and asks for changes.
    /// </summary>
    public sealed class SpeedyBotState
    {
        public static SpeedyBotState Shared { get; } = new SpeedyBotState();

        public PluginLogFile Log { get; set; }

        /// <summary>Raised (on a worker thread) whenever the mode shown on the key should change.</summary>
        public event Action Changed;

        public SpeedyMode Mode { get; private set; } = SpeedyMode.NotRunning;

        /// <summary>The app's own mode name ("on", "auto", "off"), or null when it is not running.</summary>
        public String RawMode { get; private set; }

        /// <summary>Auto-send (screenshots taken in a session go into the chat app and are sent) is switched on.</summary>
        public Boolean AutoSend { get; private set; }

        /// <summary>Auto MCP: screenshots go to whichever chat app the pointer was last over.</summary>
        public Boolean AutoMcp { get; private set; }

        /// <summary>The incident number screenshots are filed under ("#INC - 12,345"), or "" when none is set.</summary>
        public String Incident { get; private set; } = "";

        /// <summary>The last three incident numbers used, newest first (the ticket keys offer them).</summary>
        public IReadOnlyList<String> RecentIncidents { get; private set; } = Array.Empty<String>();

        private readonly String _stateFile = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library", "Application Support", "Speedy Bot", "state.json");

        private readonly Object _lock = new Object();
        private Timer _timer;
        private Boolean _reported;

        private SpeedyBotState() { }

        public void Start()
        {
            lock (this._lock)
            {
                this._timer ??= new Timer(_ => this.Refresh(), null, 0, 1000);
            }
        }

        public void Stop()
        {
            lock (this._lock)
            {
                this._timer?.Dispose();
                this._timer = null;
            }
        }

        /// <summary>Reads the state file now. Cheap: a few hundred bytes.</summary>
        public void Refresh()
        {
            var (mode, raw, settings) = this.Read();
            Boolean changed;
            lock (this._lock)
            {
                changed = mode != this.Mode || raw != this.RawMode || settings.AutoSend != this.AutoSend
                    || settings.AutoMcp != this.AutoMcp || settings.Incident != this.Incident
                    || String.Join("\n", settings.Recent) != String.Join("\n", this.RecentIncidents);
                this.Mode = mode;
                this.RawMode = raw;
                this.AutoSend = settings.AutoSend;
                this.AutoMcp = settings.AutoMcp;
                this.Incident = settings.Incident;
                this.RecentIncidents = settings.Recent;
            }
            // The first look after the log is available is always written: build.sh waits for this line to know
            // the plugin really runs (the service logs "Started loading" before it knows whether loading worked).
            if (!this._reported && this.Log != null)
            {
                this._reported = true;
                this.Log.Info($"SpeedyBot plugin running; Speedy Bot is {mode}");
            }
            if (changed)
            {
                this.Log?.Info($"Speedy Bot is now {mode}");
                try { this.Changed?.Invoke(); } catch (Exception ex) { this.Log?.Error(ex, "repaint failed"); }
            }
        }

        private (SpeedyMode, String, (Boolean AutoSend, Boolean AutoMcp, String Incident, IReadOnlyList<String> Recent)) Read()
        {
            try
            {
                if (!File.Exists(this._stateFile))
                {
                    return (SpeedyMode.NotRunning, null, (false, false, "", Array.Empty<String>()));
                }
                using var doc = JsonDocument.Parse(File.ReadAllText(this._stateFile));
                var root = doc.RootElement;
                var running = root.TryGetProperty("running", out var r) && r.ValueKind == JsonValueKind.True;
                var pid = root.TryGetProperty("pid", out var p) && p.TryGetInt32(out var n) ? n : 0;
                var settings = (
                    root.TryGetProperty("autoSend", out var s) && s.ValueKind == JsonValueKind.True,
                    root.TryGetProperty("autoMCP", out var c) && c.ValueKind == JsonValueKind.True,
                    root.TryGetProperty("incident", out var i) && i.ValueKind == JsonValueKind.String ? i.GetString() ?? "" : "",
                    ReadRecent(root));
                if (!running || !IsSpeedyBot(pid))
                {
                    return (SpeedyMode.NotRunning, null, settings);
                }
                var mode = root.TryGetProperty("mode", out var m) ? m.GetString() : null;
                var active = root.TryGetProperty("active", out var a) && a.ValueKind == JsonValueKind.True;
                return mode switch
                {
                    "on" => (SpeedyMode.On, mode, settings),
                    "auto" => (active ? SpeedyMode.AutoActive : SpeedyMode.AutoWaiting, mode, settings),
                    _ => (SpeedyMode.Off, mode ?? "off", settings),
                };
            }
            catch (Exception)
            {
                // Read while the app was replacing the file, or a file from another version: keep what is shown.
                lock (this._lock) { return (this.Mode, this.RawMode, (this.AutoSend, this.AutoMcp, this.Incident, this.RecentIncidents)); }
            }
        }

        private static IReadOnlyList<String> ReadRecent(JsonElement root)
        {
            var list = new List<String>();
            if (root.TryGetProperty("recentIncidents", out var r) && r.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in r.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String && !String.IsNullOrEmpty(item.GetString()) && list.Count < 3)
                    {
                        list.Add(item.GetString());
                    }
                }
            }
            return list;
        }

        /// <summary>The file says running, but a crash leaves it saying so: the process must still be there.</summary>
        private static Boolean IsSpeedyBot(Int32 pid)
        {
            if (pid <= 0)
            {
                return false;
            }
            try
            {
                using var process = Process.GetProcessById(pid);
                return !process.HasExited && process.ProcessName.Contains("Speedy", StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception)
            {
                return false;
            }
        }

        /// <summary>
        /// Asks Speedy Bot to do something: speedybot://toggle, enable, on, auto, off, multiping. `open -g` keeps
        /// whatever the tech is working in at the front, and starts Speedy Bot (quietly) if it is not running.
        /// </summary>
        public void Send(String action) => ThreadPool.QueueUserWorkItem(_ => this.SendNow(action));

        /// <summary>Runs on a worker thread: a key press must never wait on `open`.</summary>
        private void SendNow(String action)
        {
            try
            {
                var info = new ProcessStartInfo("/usr/bin/open") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
                info.ArgumentList.Add("-g");
                info.ArgumentList.Add("speedybot://" + action);
                using var process = Process.Start(info);
                process?.WaitForExit(5000);
                if (process != null && process.HasExited && process.ExitCode != 0)
                {
                    this.Log?.Warning($"open speedybot://{action} failed ({process.ExitCode}): {process.StandardError.ReadToEnd().Trim()}");
                }
            }
            catch (Exception ex)
            {
                this.Log?.Error(ex, $"could not send speedybot://{action}");
            }
            // The app answers in a fraction of a second; show it then rather than at the next tick.
            foreach (var delay in new[] { 200, 600, 1500, 3500 })
            {
                ThreadPool.QueueUserWorkItem(_ => { Thread.Sleep(delay); this.Refresh(); });
            }
        }
    }
}
