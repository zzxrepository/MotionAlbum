using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace LivePhotoViewer.WPF.Core
{
    public sealed record AppQuote(string Text, string? Source)
    {
        public string DisplayText => string.IsNullOrWhiteSpace(Source) ? $"❝  {Text}" : $"❝  {Text}  ·  {Source}";
    }

    public static class QuoteManager
    {
        public static IReadOnlyList<AppQuote> Load()
        {
            var quotes = new List<AppQuote>
            {
                new("当时只道是寻常", "纳兰性德"),
                new("诗酒趁年华", "苏轼"),
                new("平凡的一天，也值得收藏", "灵动相册"),
                new("把时间折好，放进相册", "灵动相册"),
                new("照片不说话，却替我们记得", "灵动相册")
            };
            try
            {
                string file = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "MotionAlbum", "quotes.txt");
                if (!File.Exists(file)) return quotes;
                foreach (string line in File.ReadLines(file))
                {
                    string trimmed = line.Trim();
                    if (trimmed.Length == 0) continue;
                    string[] parts = trimmed.Split(new[] { " — " }, 2, StringSplitOptions.None);
                    quotes.Add(new AppQuote(parts[0], parts.Length > 1 ? parts[1] : null));
                }
            }
            catch { }
            return quotes.DistinctBy(quote => quote.DisplayText).ToList();
        }
    }
}
