namespace Loupedeck.SpeedyBotPlugin
{
    using System;

    /// <summary>Keys for one mode each (On, Auto, Off) and for the Multi Ping page. The current mode's key lights up.</summary>
    public class ModeCommand : PluginDynamicCommand
    {
        public ModeCommand()
            : base(displayName: "Speedy Bot Mode", description: "Switch Speedy Bot to one mode, or open Multi Ping.", groupName: "Speedy Bot")
        {
            this.AddParameter("on", "Speedy Bot: On", "Speedy Bot");
            this.AddParameter("auto", "Speedy Bot: Auto", "Speedy Bot");
            this.AddParameter("off", "Speedy Bot: Off", "Speedy Bot");
            this.AddParameter("multiping", "Speedy Bot: Multi Ping", "Speedy Bot");
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
            if (actionParameter is "on" or "auto" or "off" or "multiping")
            {
                SpeedyBotState.Shared.Send(actionParameter);
            }
        }

        protected override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) => actionParameter switch
        {
            "on" => "Speedy Bot On",
            "auto" => "Speedy Bot Auto",
            "off" => "Speedy Bot Off",
            "multiping" => "Multi Ping",
            _ => "Speedy Bot",
        };

        protected override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize)
        {
            var state = SpeedyBotState.Shared;
            var current = state.RawMode == actionParameter;
            return actionParameter switch
            {
                "on" => KeyArt.Draw(imageSize, "ON", current ? KeyArt.Green : KeyArt.Grey, !current),
                "auto" => KeyArt.Draw(imageSize, "AUTO", current ? (state.Mode == SpeedyMode.AutoActive ? KeyArt.Green : KeyArt.Blue) : KeyArt.Grey, !current),
                "off" => KeyArt.Draw(imageSize, "OFF", current ? KeyArt.Grey : KeyArt.Grey, !current),
                "multiping" => KeyArt.Draw(imageSize, "PING", KeyArt.Blue, false),
                _ => KeyArt.Draw(imageSize, "?", KeyArt.Grey, true),
            };
        }
    }
}
