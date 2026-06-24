using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace LivePhotoViewer.WPF.Controls
{
    public partial class ThumbnailCard : UserControl
    {
        public string FilePath { get; }
        public bool IsLivePhoto { get; private set; }
        public bool IsFavorite
        {
            get => _isFavorite;
            set
            {
                _isFavorite = value;
                UpdateFavoriteStyle();
            }
        }

        private bool _isFavorite;

        public event EventHandler<string>? PhotoClicked;
        public event EventHandler<string>? FavoriteToggled;

        public ThumbnailCard(string filePath, bool isFavorite = false, bool isLoading = false)
        {
            FilePath = filePath;
            _isFavorite = isFavorite;
            InitializeComponent();
            UpdateFavoriteStyle();

            string name = Path.GetFileName(filePath);
            FileNameText.Text = name.Length <= 20 ? name : name.Substring(0, 17) + "...";

            if (!isLoading)
            {
                LoadingOverlay.Visibility = Visibility.Collapsed;
                ThumbImage.Visibility = Visibility.Visible;
            }

            MouseDoubleClick += (s, e) =>
            {
                if (e.ChangedButton == MouseButton.Left)
                    PhotoClicked?.Invoke(this, FilePath);
            };

            MouseEnter += (s, e) => CardBorder.BorderBrush = new SolidColorBrush(Color.FromArgb(255, 0, 122, 255));
            MouseLeave += (s, e) => CardBorder.BorderBrush = Brushes.Transparent;
        }

        public void SetLoaded(BitmapImage? bitmap, bool isLive)
        {
            IsLivePhoto = isLive;
            LiveBadge.Visibility = isLive ? Visibility.Visible : Visibility.Collapsed;

            if (bitmap != null)
            {
                ThumbImage.Source = bitmap;
                ThumbImage.Visibility = Visibility.Visible;
            }
            else
            {
                ThumbImage.Visibility = Visibility.Collapsed;
            }
            LoadingOverlay.Visibility = Visibility.Collapsed;
        }

        public void SetTags(List<string> tags)
        {
            TagsPanel.Children.Clear();
            if (tags == null || tags.Count == 0)
            {
                TagsPanel.Visibility = Visibility.Collapsed;
                return;
            }

            TagsPanel.Visibility = Visibility.Visible;
            foreach (var tag in tags)
            {
                var border = new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(60, 0, 122, 255)),
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(4, 1, 4, 1),
                    Margin = new Thickness(0, 0, 4, 2)
                };
                var text = new TextBlock
                {
                    Text = tag,
                    FontSize = 9,
                    Foreground = new SolidColorBrush(Color.FromArgb(255, 0, 122, 255))
                };
                border.Child = text;
                TagsPanel.Children.Add(border);
            }
        }

        private void FavButton_Click(object sender, RoutedEventArgs e)
        {
            e.Handled = true;
            IsFavorite = !IsFavorite;
            FavoriteToggled?.Invoke(this, FilePath);
        }

        private void UpdateFavoriteStyle()
        {
            if (_isFavorite)
            {
                FavIcon.Text = "★";
                FavIcon.Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 149, 0));
            }
            else
            {
                FavIcon.Text = "☆";
                FavIcon.Foreground = new SolidColorBrush(Color.FromArgb(255, 136, 136, 136));
            }
        }
    }
}
