namespace Loupedeck.SpeedyBotPlugin
{
    using System;
    using System.IO;

    /// <summary>The key's picture: the Speedy Bot icon over a word in the state's colour.</summary>
    internal static class KeyArt
    {
        private static readonly BitmapColor Background = new BitmapColor(18, 18, 18);
        public static readonly BitmapColor Green = new BitmapColor(0x2D, 0xD4, 0x64);
        public static readonly BitmapColor Blue = new BitmapColor(0x3D, 0x9B, 0xFF);
        public static readonly BitmapColor Grey = new BitmapColor(0x8E, 0x8E, 0x93);
        public static readonly BitmapColor White = new BitmapColor(0xF2, 0xF2, 0xF7);

        private static BitmapImage _icon;

        private static BitmapImage Icon
        {
            get
            {
                if (_icon == null)
                {
                    using var stream = typeof(KeyArt).Assembly.GetManifestResourceStream("SpeedyBot.AppIcon256.png");
                    using var memory = new MemoryStream();
                    stream.CopyTo(memory);
                    _icon = BitmapImage.FromArray(memory.ToArray());
                }
                return _icon;
            }
        }

        /// <summary>`dim`: the icon is greyed out (Speedy Bot is off or not running).</summary>
        public static BitmapImage Draw(PluginImageSize size, String word, BitmapColor wordColor, Boolean dim)
        {
            using var b = new BitmapBuilder(size);
            var w = b.Width;
            var h = b.Height;
            b.Clear(Background);
            var iconSize = (Int32)(Math.Min(w, h) * 0.58);
            var x = (w - iconSize) / 2;
            var y = (Int32)(h * 0.08);
            b.DrawImage(Icon, x, y, iconSize, iconSize, BitmapRotation.None);
            if (dim)
            {
                b.FillRectangle(x, y, iconSize, iconSize, new BitmapColor(Background, 165));
            }
            var fontSize = Math.Max(9, (Int32)(h * 0.17));
            var textTop = y + iconSize + (Int32)(h * 0.03);
            b.DrawText(word, 0, textTop, w, h - textTop, wordColor, fontSize, fontSize, BitmapBuilder.GetDefaultSpaceHeight(size), null);
            return b.ToImage();
        }

        /// <summary>The On/Off key for each state.</summary>
        public static BitmapImage ForToggle(PluginImageSize size, SpeedyMode mode) => mode switch
        {
            SpeedyMode.On => Draw(size, "ON", Green, false),
            SpeedyMode.AutoActive => Draw(size, "AUTO", Green, false),
            SpeedyMode.AutoWaiting => Draw(size, "AUTO", Blue, false),
            SpeedyMode.Off => Draw(size, "OFF", Grey, true),
            _ => Draw(size, "START", Grey, true),
        };
    }
}
