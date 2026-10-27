namespace Loupedeck.SpeedyBotPlugin
{
    using System;
    using System.IO;
    using System.Runtime.InteropServices;
    using System.Threading;

    // The keys that do something in a session: type the clipboard (⌘⇧V), capture the session window (⇧⌘2), and
    // put the waiting screenshot into the chat app without sending it, or send it. They reach Speedy Bot as Darwin
    // notifications, which only programs on this Mac can post: unlike speedybot:// links, no web page can. A
    // notification says nothing about who posted it, and sandboxed apps can post them too, so each press first
    // writes a press file into Speedy Bot's own folder (which sandboxed apps cannot reach); Speedy Bot acts only
    // on a notification whose press file is there and fresh.

    /// Posting a Darwin notification to Speedy Bot, starting it first when it is not running.
    internal static class AppSignal
    {
        /// Speedy Bot's app group (team id + bundle id); its notification names start with it.
        private const String Group = "SRPFLCC723.net.fm.speedybot";

        [DllImport("/usr/lib/libSystem.dylib")]
        private static extern UInt32 notify_post([MarshalAs(UnmanagedType.LPUTF8Str)] String name);

        private static readonly String PressFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library", "Application Support", "Speedy Bot", "keypad");

        /// The press file for this key: the time, in milliseconds since 1970, written in one go.
        private static void WritePress(String key)
        {
            Directory.CreateDirectory(PressFolder);
            var path = Path.Combine(PressFolder, key);
            var temp = path + ".tmp";
            File.WriteAllText(temp, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString());
            File.Move(temp, path, true);
        }

        public static void Post(String key)
        {
            var state = SpeedyBotState.Shared;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    if (state.Mode == SpeedyMode.NotRunning)
                    {
                        state.Send("start");
                        Thread.Sleep(2500);   // let it get going before it is asked to act
                    }
                    WritePress(key);
                    var status = notify_post(Group + ".key." + key);
                    if (status != 0)
                    {
                        state.Log?.Warning($"notify_post {key} failed ({status})");
                    }
                }
                catch (Exception ex)
                {
                    state.Log?.Error(ex, $"could not signal {key}");
                }
            });
        }

        /// White while Speedy Bot is working (On, or Auto with a session open), dimmed otherwise.
        public static BitmapImage Image(PluginImageSize size, String word)
        {
            var mode = SpeedyBotState.Shared.Mode;
            var ready = mode == SpeedyMode.On || mode == SpeedyMode.AutoActive;
            return KeyArt.Draw(size, word, ready ? KeyArt.White : KeyArt.Grey, !ready);
        }
    }

    public class TypeCommand : PluginDynamicCommand
    {
        public TypeCommand() : base("Type clipboard (⌘⇧V)", "Types the copied text into the ScreenConnect session in front, key by key, like ⌘⇧V.", "Speedy Bot") { }
        protected override Boolean OnLoad() { SpeedyBotState.Shared.Changed += this.Repaint; SpeedyBotState.Shared.Start(); return true; }
        protected override Boolean OnUnload() { SpeedyBotState.Shared.Changed -= this.Repaint; return true; }
        private void Repaint() => this.ActionImageChanged();
        protected override void RunCommand(String actionParameter) => AppSignal.Post("type");
        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => "Type";
        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize) => AppSignal.Image(imageSize, "TYPE");
    }

    public class CaptureCommand : PluginDynamicCommand
    {
        public CaptureCommand() : base("Capture session (⇧⌘2)", "Takes a screenshot of the whole ScreenConnect session window, like ⇧⌘2.", "Speedy Bot") { }
        protected override Boolean OnLoad() { SpeedyBotState.Shared.Changed += this.Repaint; SpeedyBotState.Shared.Start(); return true; }
        protected override Boolean OnUnload() { SpeedyBotState.Shared.Changed -= this.Repaint; return true; }
        private void Repaint() => this.ActionImageChanged();
        protected override void RunCommand(String actionParameter) => AppSignal.Post("capture");
        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => "Capture";
        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize) => AppSignal.Image(imageSize, "CAPTURE");
    }

    public class PasteCommand : PluginDynamicCommand
    {
        public PasteCommand() : base("Paste, no send", "Puts the waiting screenshot into the chat app's message box without sending it (with none waiting, captures the session window first).", "Speedy Bot") { }
        protected override Boolean OnLoad() { SpeedyBotState.Shared.Changed += this.Repaint; SpeedyBotState.Shared.Start(); return true; }
        protected override Boolean OnUnload() { SpeedyBotState.Shared.Changed -= this.Repaint; return true; }
        private void Repaint() => this.ActionImageChanged();
        protected override void RunCommand(String actionParameter) => AppSignal.Post("paste");
        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => "Paste";
        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize) => AppSignal.Image(imageSize, "PASTE");
    }

    public class PasteSendCommand : PluginDynamicCommand
    {
        public PasteSendCommand() : base("Paste and send", "Puts the waiting screenshot into the chat app and sends it, the safe auto-send way (with none waiting, captures the session window first).", "Speedy Bot") { }
        protected override Boolean OnLoad() { SpeedyBotState.Shared.Changed += this.Repaint; SpeedyBotState.Shared.Start(); return true; }
        protected override Boolean OnUnload() { SpeedyBotState.Shared.Changed -= this.Repaint; return true; }
        private void Repaint() => this.ActionImageChanged();
        protected override void RunCommand(String actionParameter) => AppSignal.Post("pastesend");
        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => "Paste & send";
        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize) => AppSignal.Image(imageSize, "SEND");
    }
}
