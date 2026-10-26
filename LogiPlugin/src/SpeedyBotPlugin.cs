namespace Loupedeck.SpeedyBotPlugin
{
    using System;

    /// <summary>Speedy Bot on a Logitech key. Not tied to any one application: the keys work whatever is in front.</summary>
    public class SpeedyBotPlugin : Plugin
    {
        public override Boolean UsesApplicationApiOnly => true;

        public override Boolean HasNoApplication => true;

        public override void Load()
        {
            SpeedyBotState.Shared.Log = this.Log;
            SpeedyBotState.Shared.Start();
            this.Log.Info("Speedy Bot plugin loaded");
        }

        public override void Unload() => SpeedyBotState.Shared.Stop();
    }

    /// <summary>Required by the plugin service; the plugin has no application of its own.</summary>
    public class SpeedyBotApplication : ClientApplication
    {
        protected override String GetProcessName() => "";

        protected override String GetBundleName() => "";

        public override ClientApplicationStatus GetApplicationStatus() => ClientApplicationStatus.Unknown;
    }
}
