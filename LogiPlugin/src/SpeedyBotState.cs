namespace Loupedeck.SpeedyBotPlugin
{
    using System;
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

        private readonly String _stateFile = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library", "Application Support", "Speedy Bot", "state.json");

        private readonly Object _lock = new Object();
        private Timer _timer;

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
            var (mode, raw) = this.Read();
            Boolean changed;
            lock (this._lock)
            {
                changed = mode != this.Mode || raw != this.RawMode;
                this.Mode = mode;
                this.RawMode = raw;
            }
            if (changed)
            {
                this.Log?.Info($"Speedy Bot is now {mode}");
                try { this.Changed?.Invoke(); } catch (Exception ex) { this.Log?.Error(ex, "repaint failed"); }
            }
        }

        private (SpeedyMode, String) Read()
        {
            try
            {
                if (!File.Exists(this._stateFile))
                {
                    return (SpeedyMode.NotRunning, null);
                }
                using var doc = JsonDocument.Parse(File.ReadAllText(this._stateFile));
                var root = doc.RootElement;
                var running = root.TryGetProperty("running", out var r) && r.ValueKind == JsonValueKind.True;
                var pid = root.TryGetProperty("pid", out var p) && p.TryGetInt32(out var n) ? n : 0;
                if (!running || !IsSpeedyBot(pid))
                {
                    return (SpeedyMode.NotRunning, null);
                }
                var mode = root.TryGetProperty("mode", out var m) ? m.GetString() : null;
                var active = root.TryGetProperty("active", out var a) && a.ValueKind == JsonValueKind.True;
                return mode switch
                {
                    "on" => (SpeedyMode.On, mode),
                    "auto" => (active ? SpeedyMode.AutoActive : SpeedyMode.AutoWaiting, mode),
                    _ => (SpeedyMode.Off, mode ?? "off"),
                };
            }
            catch (Exception)
            {
                // Read while the app was replacing the file, or a file from another version: keep what is shown.
                lock (this._lock) { return (this.Mode, this.RawMode); }
            }
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
