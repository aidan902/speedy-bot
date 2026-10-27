namespace Loupedeck.SpeedyBotPlugin
{
    using System;

    // One key per mode (On, Auto, Off) and one for the Multi Ping page; the current mode's key lights up.
    // Each is its own plain command (no parameters): Logi Options+ shows a warning sign in place of a
    // parameterized command's picture, while a plain command's picture shows like on the keypad.

    /// <summary>What the four keys share: the link they send and how they draw themselves.</summary>
    internal static class ModeKey
    {
        public static BitmapImage Image(PluginImageSize size, String mode)
        {
            var state = SpeedyBotState.Shared;
            var current = state.RawMode == mode;
            return mode switch
            {
                // Each mode in its own colour (On green, Auto orange, Off red), full strength on the current mode's
                // key, faded on the others. Auto waiting for a session: orange with the icon dimmed.
                "on" => KeyArt.Draw(size, "ON", current ? KeyArt.Green : KeyArt.Muted(KeyArt.Green), !current),
                "auto" => KeyArt.Draw(size, "AUTO", current ? KeyArt.Orange : KeyArt.Muted(KeyArt.Orange), !current || state.Mode != SpeedyMode.AutoActive),
                "off" => KeyArt.Draw(size, "OFF", current ? KeyArt.Red : KeyArt.Muted(KeyArt.Red), !current),
                _ => KeyArt.Draw(size, "PING", KeyArt.Blue, false),
            };
        }
    }

    public class OnCommand : PluginDynamicCommand
    {
        public OnCommand() : base("Speedy Bot On", "Switches Speedy Bot on (works everywhere). Lights up while it is On.", "Speedy Bot") { }
        protected override Boolean OnLoad() { SpeedyBotState.Shared.Changed += this.Repaint; SpeedyBotState.Shared.Start(); return true; }
        protected override Boolean OnUnload() { SpeedyBotState.Shared.Changed -= this.Repaint; return true; }
        private void Repaint() => this.ActionImageChanged();
        protected override void RunCommand(String actionParameter) => SpeedyBotState.Shared.Send("on");
        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => "Speedy Bot On";
        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize) => ModeKey.Image(imageSize, "on");
    }

    public class AutoCommand : PluginDynamicCommand
    {
        public AutoCommand() : base("Speedy Bot Auto", "Switches Speedy Bot to Auto (works only while a ScreenConnect session is open). Lights up while it is in Auto.", "Speedy Bot") { }
        protected override Boolean OnLoad() { SpeedyBotState.Shared.Changed += this.Repaint; SpeedyBotState.Shared.Start(); return true; }
        protected override Boolean OnUnload() { SpeedyBotState.Shared.Changed -= this.Repaint; return true; }
        private void Repaint() => this.ActionImageChanged();
        protected override void RunCommand(String actionParameter) => SpeedyBotState.Shared.Send("auto");
        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => "Speedy Bot Auto";
        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize) => ModeKey.Image(imageSize, "auto");
    }

    public class OffCommand : PluginDynamicCommand
    {
        public OffCommand() : base("Speedy Bot Off", "Switches Speedy Bot off.", "Speedy Bot") { }
        protected override Boolean OnLoad() { SpeedyBotState.Shared.Changed += this.Repaint; SpeedyBotState.Shared.Start(); return true; }
        protected override Boolean OnUnload() { SpeedyBotState.Shared.Changed -= this.Repaint; return true; }
        private void Repaint() => this.ActionImageChanged();
        protected override void RunCommand(String actionParameter) => SpeedyBotState.Shared.Send("off");
        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => "Speedy Bot Off";
        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize) => ModeKey.Image(imageSize, "off");
    }

    public class MultiPingCommand : PluginDynamicCommand
    {
        public MultiPingCommand() : base("Multi Ping", "Opens Speedy Bot's Multi Ping page.", "Speedy Bot") { }
        protected override void RunCommand(String actionParameter) => SpeedyBotState.Shared.Send("multiping");
        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => "Multi Ping";
        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize) => ModeKey.Image(imageSize, "multiping");
    }
}
