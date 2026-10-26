namespace Loupedeck.SpeedyBotPlugin
{
    using System;

    /// <summary>One key: shows whether Speedy Bot is on, and turns it off or back on when pressed.</summary>
    public class ToggleCommand : PluginDynamicCommand
    {
        public ToggleCommand()
            : base(displayName: "Speedy Bot On/Off",
                   description: "Turns Speedy Bot off, or back on in the mode it was using (On or Auto). The key shows the live state.",
                   groupName: "Speedy Bot")
        {
        }

        protected override Boolean OnLoad()
        {
            SpeedyBotState.Shared.Changed += this.Repaint;
            SpeedyBotState.Shared.Start();
            return true;
        }

        protected override Boolean OnUnload()
        {
            SpeedyBotState.Shared.Changed -= this.Repaint;
            return true;
        }

        private void Repaint() => this.ActionImageChanged();

        protected override void RunCommand(String actionParameter)
        {
            // Not running: the press means "turn it on", which also starts it.
            var state = SpeedyBotState.Shared;
            state.Send(state.Mode == SpeedyMode.NotRunning ? "enable" : "toggle");
        }

        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => "Speedy Bot";

        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize)
            => KeyArt.ForToggle(imageSize, SpeedyBotState.Shared.Mode);
    }
}
