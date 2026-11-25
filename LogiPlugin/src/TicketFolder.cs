namespace Loupedeck.SpeedyBotPlugin
{
    using System;
    using System.Collections.Generic;

    /// <summary>
    /// The Ticket key as a folder: it shows the current incident number, and a press opens a page of its own with
    /// the three recent incident numbers across the top row, New at the bottom middle and Back at the bottom left.
    /// Picking one tells Speedy Bot (ticket1-3, ticketnew) and returns to the Speedy Bot page.
    /// </summary>
    public class TicketFolder : PluginDynamicFolder
    {
        private Boolean _loaded;

        public TicketFolder()
        {
            this.DisplayName = "Ticket number (recent)";
            this.Description = "Shows the incident number. A press opens the three recent ones and New.";
            this.GroupName = "Speedy Bot";
        }

        public override Boolean Load()
        {
            SpeedyBotState.Shared.Changed += this.Repaint;
            SpeedyBotState.Shared.Start();
            this._loaded = true;
            return true;
        }

        public override Boolean Unload()
        {
            this._loaded = false;
            SpeedyBotState.Shared.Changed -= this.Repaint;
            return true;
        }

        /// <summary>No Back key added by the service at the top left: the top row is the recent numbers. Back is
        /// placed at the bottom left instead (see below).</summary>
        public override PluginDynamicFolderNavigation GetNavigationArea(DeviceType _) => PluginDynamicFolderNavigation.EncoderArea;

        /// <summary>Always the same nine keys: recent 1, 2, 3 / empty row / Back, New, empty. A recent number that
        /// does not exist yet is drawn as a dash rather than removed, so the keys never move.</summary>
        public override IEnumerable<String> GetButtonPressActionNames(DeviceType deviceType) => new[]
        {
            this.CreateCommandName("1"), this.CreateCommandName("2"), this.CreateCommandName("3"),
            null, null, null,
            NavigateUpActionName, this.CreateCommandName("new"), null,
        };

        public override String GetButtonDisplayName(PluginImageSize imageSize) => "Ticket";

        public override BitmapImage GetButtonImage(PluginImageSize imageSize)
        {
            var running = SpeedyBotState.Shared.Mode != SpeedyMode.NotRunning;
            var digits = Digits(SpeedyBotState.Shared.Incident);
            return KeyArt.Draw(imageSize, digits.Length > 0 ? "#" + digits : "TICKET", running ? KeyArt.Green : KeyArt.Grey, !running);
        }

        public override String GetCommandDisplayName(String actionParameter, PluginImageSize imageSize) =>
            actionParameter == "new" ? "New ticket" : Recent(actionParameter) ?? "No recent ticket";

        public override BitmapImage GetCommandImage(String actionParameter, PluginImageSize imageSize)
        {
            if (actionParameter == "new")
            {
                return KeyArt.Draw(imageSize, "NEW", KeyArt.Green, false);
            }
            var recent = Recent(actionParameter);
            if (recent == null)
            {
                return KeyArt.Draw(imageSize, "-", KeyArt.Grey, true);
            }
            var digits = Digits(recent);
            var label = digits.Length > 0 ? "#" + digits : recent;
            // The one in use now is green; the others white.
            return KeyArt.Draw(imageSize, label, recent == SpeedyBotState.Shared.Incident ? KeyArt.Green : KeyArt.White, false);
        }

        public override void RunCommand(String actionParameter)
        {
            if (actionParameter == "new")
            {
                AppSignal.Post("ticketnew");
            }
            else if (Recent(actionParameter) != null)
            {
                AppSignal.Post("ticket" + actionParameter);
            }
            else
            {
                return;   // an empty place: stay on this page
            }
            this.Close();
        }

        /// <summary>Recent number "1".."3" (newest first), or null when there is none in that place.</summary>
        private static String Recent(String place)
        {
            var list = SpeedyBotState.Shared.RecentIncidents;
            return Int32.TryParse(place, out var n) && n >= 1 && n <= list.Count ? list[n - 1] : null;
        }

        /// <summary>"#INC - 12,345" -> "12345".</summary>
        private static String Digits(String incident) => new String(Array.FindAll((incident ?? "").ToCharArray(), Char.IsDigit));

        private void Repaint()
        {
            if (!this._loaded)
            {
                return;
            }
            try
            {
                this.CommandImageChanged("1");
                this.CommandImageChanged("2");
                this.CommandImageChanged("3");
                // The folder's own key on the Speedy Bot page.
                this.Plugin?.OnActionImageChanged("#DynamicFolder", this.Name, false);
            }
            catch (Exception)
            {
                // A repaint while the service is setting the page up: the next change paints it.
            }
        }
    }
}
