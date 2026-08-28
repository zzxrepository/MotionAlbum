using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LivePhotoViewer.WPF.Models;

namespace LivePhotoViewer.WPF.Controls
{
    public partial class ThumbnailCard : UserControl
    {
        private static readonly Brush FocusBrush = new SolidColorBrush(Color.FromRgb(245, 158, 11));
        private readonly PhotoItem _photo;
        private bool _isFocused;
        private bool _isShowcasePreviewActive;
        private int _showcaseLoadVersion;
        private BitmapSource? _thumbnailSource;

        public string FilePath => _photo.FilePath;
        public PhotoItem Photo => _photo;

        public bool IsFavorite
        {
            get => _photo.IsFavorite;
            set
            {
                _photo.IsFavorite = value;
                UpdateFavoriteStyle();
            }
        }

        public event EventHandler<string>? PhotoFocused;
        public event EventHandler<string>? PhotoOpened;
        public event EventHandler<string>? FavoriteToggled;
        public event EventHandler<string>? RevealRequested;
        public event EventHandler<string>? TrashRequested;

        public ThumbnailCard(PhotoItem photo, bool isLoading = false)
        {
            _photo = photo;
            InitializeComponent();
            FileNameText.Text = photo.FileName;
            UpdateMetaText();
            UpdateFavoriteStyle();
            UpdateMediaBadge();

            if (!isLoading) LoadingText.Visibility = Visibility.Collapsed;

            PreviewMouseLeftButtonDown += Card_PreviewMouseLeftButtonDown;
            MouseDoubleClick += Card_MouseDoubleClick;
            MouseEnter += (_, _) =>
            {
                if (!_isFocused) CardBorder.BorderBrush = (Brush)FindResource("HoverBorderBrush");
            };
            MouseLeave += (_, _) =>
            {
                if (!_isFocused) CardBorder.BorderBrush = (Brush)FindResource("BorderBrush");
            };
            ContextMenu = BuildContextMenu();
        }

        public void SetLoaded(BitmapImage? bitmap, bool isLive)
        {
            _photo.IsLivePhoto = isLive;
            if (bitmap != null)
            {
                if (_photo.Width <= 0 || _photo.Height <= 0)
                {
                    _photo.Width = bitmap.PixelWidth;
                    _photo.Height = bitmap.PixelHeight;
                }
                _thumbnailSource = bitmap;
                ThumbImage.Source = bitmap;
                ThumbImage.Visibility = Visibility.Visible;
            }
            LoadingText.Visibility = Visibility.Collapsed;
            UpdateMediaBadge();
            UpdateMetaText();
            if (_isShowcasePreviewActive)
            {
                _isShowcasePreviewActive = false;
                SetHighResolutionPreview(true);
            }
        }

        public void SetDisplaySize(double width, bool showcaseMode)
        {
            width = Math.Max(72, width);
            Width = width;
            double contentWidth = Math.Max(48, width - 16);
            double imageHeight;
            if (showcaseMode)
            {
                double aspect = _photo.Width > 0 && _photo.Height > 0
                    ? Math.Clamp((double)_photo.Width / _photo.Height, 0.75, 2.4)
                    : 1.6;
                imageHeight = Math.Clamp(contentWidth / aspect, 360, 640);
                ThumbImage.Stretch = Stretch.Uniform;
                ImageHost.Background = new SolidColorBrush(Color.FromRgb(18, 18, 20));
                ShowcaseHint.Visibility = Visibility.Visible;
                DetailsPanel.Visibility = Visibility.Visible;
                FileNameText.FontSize = 15;
                CardBorder.CornerRadius = new CornerRadius(16);
                CardBorder.Padding = new Thickness(12);
            }
            else if (width >= 150)
            {
                imageHeight = Math.Clamp(contentWidth * 0.68, 122, 360);
                ThumbImage.Stretch = Stretch.UniformToFill;
                ImageHost.SetResourceReference(Border.BackgroundProperty, "ThumbPlaceholderBgBrush");
                ShowcaseHint.Visibility = Visibility.Collapsed;
                DetailsPanel.Visibility = Visibility.Visible;
                FileNameText.FontSize = 12;
                CardBorder.CornerRadius = new CornerRadius(10);
                CardBorder.Padding = new Thickness(8);
            }
            else
            {
                imageHeight = width;
                ThumbImage.Stretch = Stretch.UniformToFill;
                ImageHost.SetResourceReference(Border.BackgroundProperty, "ThumbPlaceholderBgBrush");
                ShowcaseHint.Visibility = Visibility.Collapsed;
                DetailsPanel.Visibility = Visibility.Collapsed;
                CardBorder.CornerRadius = new CornerRadius(6);
                CardBorder.Padding = new Thickness(0);
            }
            ImageHost.Height = imageHeight;
        }

        public async void SetHighResolutionPreview(bool active)
        {
            if (_isShowcasePreviewActive == active) return;
            _isShowcasePreviewActive = active;
            int version = ++_showcaseLoadVersion;
            if (!active || _photo.IsVideo)
            {
                ThumbImage.Source = _thumbnailSource;
                return;
            }

            BitmapImage? highResolution = await Task.Run(() => LoadHighResolutionPreview(_photo.FilePath));
            if (version != _showcaseLoadVersion || !_isShowcasePreviewActive || highResolution == null) return;
            ThumbImage.Source = highResolution;
        }

        public void SetFocused(bool focused)
        {
            _isFocused = focused;
            FocusBadge.Visibility = focused ? Visibility.Visible : Visibility.Collapsed;
            CardBorder.BorderBrush = focused ? FocusBrush : (Brush)FindResource("BorderBrush");
            CardBorder.BorderThickness = focused ? new Thickness(3) : new Thickness(1);
        }

        public void SetTags(System.Collections.Generic.List<string> tags)
        {
            _photo.Tags = tags ?? new System.Collections.Generic.List<string>();
            TagsPanel.Children.Clear();
            foreach (string tag in _photo.Tags.GetRange(0, Math.Min(2, _photo.Tags.Count)))
            {
                TagsPanel.Children.Add(new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(35, 59, 130, 246)),
                    CornerRadius = new CornerRadius(5),
                    Padding = new Thickness(5, 2, 5, 2),
                    Margin = new Thickness(0, 0, 4, 0),
                    Child = new TextBlock { Text = tag, FontSize = 9, Foreground = (Brush)FindResource("SubTextBrush") }
                });
            }
        }

        private void Card_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (FindVisualParent<Button>(e.OriginalSource as DependencyObject) != null) return;
            PhotoFocused?.Invoke(this, FilePath);
        }

        private void Card_MouseDoubleClick(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton != MouseButton.Left ||
                FindVisualParent<Button>(e.OriginalSource as DependencyObject) != null) return;
            PhotoOpened?.Invoke(this, FilePath);
            e.Handled = true;
        }

        private void FavoriteButton_Click(object sender, RoutedEventArgs e)
        {
            e.Handled = true;
            IsFavorite = !IsFavorite;
            FavoriteToggled?.Invoke(this, FilePath);
        }

        private ContextMenu BuildContextMenu()
        {
            var menu = new ContextMenu();
            var open = new MenuItem { Header = "查看照片" };
            open.Click += (_, _) => PhotoOpened?.Invoke(this, FilePath);
            var favorite = new MenuItem();
            favorite.Click += (_, _) =>
            {
                IsFavorite = !IsFavorite;
                FavoriteToggled?.Invoke(this, FilePath);
            };
            var reveal = new MenuItem { Header = "在文件资源管理器中显示" };
            reveal.Click += (_, _) => RevealRequested?.Invoke(this, FilePath);
            var trash = new MenuItem { Header = "移入回收站" };
            trash.Click += (_, _) => TrashRequested?.Invoke(this, FilePath);
            menu.Items.Add(open);
            menu.Items.Add(favorite);
            menu.Items.Add(new Separator());
            menu.Items.Add(reveal);
            menu.Items.Add(trash);
            menu.Opened += (_, _) => favorite.Header = _photo.IsFavorite ? "取消喜欢" : "加入我喜欢";
            return menu;
        }

        private void UpdateFavoriteStyle()
        {
            FavoriteIcon.Text = _photo.IsFavorite ? "♥" : "♡";
            FavoriteIcon.Foreground = _photo.IsFavorite ? Brushes.Red : Brushes.White;
            FavoriteButton.ToolTip = _photo.IsFavorite ? "取消喜欢" : "加入我喜欢";
        }

        private void UpdateMediaBadge()
        {
            if (_photo.IsLivePhoto)
            {
                MediaBadgeText.Text = "◎ LIVE";
                MediaBadge.Visibility = Visibility.Visible;
            }
            else if (_photo.IsVideo)
            {
                MediaBadgeText.Text = "▶ VIDEO";
                MediaBadge.Visibility = Visibility.Visible;
            }
            else
            {
                MediaBadge.Visibility = Visibility.Collapsed;
            }
        }

        private void UpdateMetaText()
        {
            string size = FormatBytes(_photo.FileSize);
            string dimensions = _photo.Width > 0 && _photo.Height > 0 ? $"  ·  {_photo.Width} × {_photo.Height}" : string.Empty;
            MetaText.Text = size + dimensions;
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
            if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024):F1} MB";
            return $"{bytes / (1024.0 * 1024 * 1024):F2} GB";
        }

        private static BitmapImage? LoadHighResolutionPreview(string path)
        {
            try
            {
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.DecodePixelWidth = 2400;
                image.UriSource = new Uri(path, UriKind.Absolute);
                image.EndInit();
                image.Freeze();
                return image;
            }
            catch { return null; }
        }

        private static T? FindVisualParent<T>(DependencyObject? child) where T : DependencyObject
        {
            while (child != null)
            {
                if (child is T match) return match;
                child = VisualTreeHelper.GetParent(child);
            }
            return null;
        }
    }
}
