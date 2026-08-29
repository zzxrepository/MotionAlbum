using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LibVLCSharp.Shared;
using LivePhotoViewer.WPF.Controls;
using LivePhotoViewer.WPF.Core;
using LivePhotoViewer.WPF.Models;
using Microsoft.Win32;
using VlcMedia = LibVLCSharp.Shared.Media;
using VlcMediaPlayer = LibVLCSharp.Shared.MediaPlayer;

namespace LivePhotoViewer.WPF
{
    public partial class MainWindow : Window
    {
        private enum LibraryFilter { All, Live, Video, Favorite }

        private readonly FavoritesManager _favoriteStore = new();
        private readonly TagsManager _tagStore = new();
        private readonly RecentFoldersManager _recentFolders = new();
        private readonly HoldFrameManager _holdFrameStore = new();
        private readonly UserSettingsManager _settings = new();
        private readonly LibraryIndexStore _libraryIndex = new();
        private readonly IReadOnlyList<AppQuote> _quotes = QuoteManager.Load();
        private readonly DispatcherTimer _quoteTimer = new() { Interval = TimeSpan.FromSeconds(12) };
        private readonly Dictionary<string, ThumbnailCard> _cardMap = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, BitmapImage?> _thumbnailMap = new(StringComparer.OrdinalIgnoreCase);
        private readonly SemaphoreSlim _thumbnailSemaphore = new(4, 4);
        private readonly double[] _galleryZoomStops = { 72, 96, 126, 160, 220, 300, 420, 520, 720, 900, 1100 };

        private List<PhotoItem> _photos = new();
        private List<PhotoItem> _visiblePhotos = new();
        private CancellationTokenSource? _loadCts;
        private CancellationTokenSource? _showcasePreviewCts;
        private string _currentDirectory = string.Empty;
        private string _browsingDirectory = string.Empty;
        private LibraryFilter _filter = LibraryFilter.All;
        private string? _selectedTag;
        private string _tagSidebarSignature = string.Empty;
        private string? _focusedPhotoId;
        private string? _previousFocusedPhotoId;
        private double _galleryCardSize = 126;
        private bool _isSidebarVisible = true;
        private bool _suppressGalleryZoomEvent;
        private double _galleryManipulationBaseSize;
        private bool _groupByTime = true;
        private bool _isWorking;
        private bool _suppressDirectorySelection;
        private int _quoteIndex;

        private int _viewerIndex = -1;
        private LibVLC? _libVlc;
        private VlcMediaPlayer? _mediaPlayer;
        private VlcMedia? _currentVlcMedia;
        private int _mediaSessionId;
        private bool _isEditingCoverFrame;
        private bool _suppressCoverSlider;

        private double _viewerScale = 1;
        private bool _isDraggingViewer;
        private Point _dragStart;
        private Point _dragStartTranslation;
        private DateTime _lastViewerClick;
        private Point _lastViewerClickPosition;
        private double _viewerManipulationBaseScale;

        public MainWindow()
        {
            InitializeComponent();
            Loaded += MainWindow_Loaded;
            Closing += MainWindow_Closing;
            SizeChanged += (_, _) =>
            {
                if (IsShowcaseMode && _visiblePhotos.Count > 0) RenderGallery();
            };
        }

        private bool IsShowcaseMode => _galleryCardSize >= 520;

        private void MainWindow_Loaded(object sender, RoutedEventArgs e)
        {
            _isSidebarVisible = _settings.SidebarVisible;
            ApplySidebarVisibility();
            UpdateThemeButtonIcon();
            UpdateFilterVisuals();
            UpdateCounts();
            try
            {
                _libVlc = new LibVLC("--quiet", "--no-video-title-show", "--intf=dummy");
            }
            catch (Exception ex)
            {
                SetStatus($"播放器初始化失败：{ex.Message}");
            }

            if (_quotes.Count > 0)
            {
                _quoteIndex = (int)((uint)Environment.TickCount % (uint)_quotes.Count);
                QuoteText.Text = _quotes[_quoteIndex].DisplayText;
                _quoteTimer.Tick += (_, _) =>
                {
                    _quoteIndex = (_quoteIndex + 1) % _quotes.Count;
                    QuoteText.Text = _quotes[_quoteIndex].DisplayText;
                };
                _quoteTimer.Start();
            }

            _recentFolders.RemoveUnavailable();
            string? lastDirectory = _recentFolders.Paths.FirstOrDefault(Directory.Exists);
            if (lastDirectory != null) _ = OpenDirectoryAsync(lastDirectory, remember: false);
        }

        private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
        {
            _loadCts?.Cancel();
            _showcasePreviewCts?.Cancel();
            _quoteTimer.Stop();
            StopMediaPlayback();
            _mediaPlayer?.Dispose();
            _libVlc?.Dispose();
        }

        // MARK: - Folder and scanning

        private void BtnOpenFolder_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new OpenFolderDialog
            {
                Title = "选择包含手机照片的文件夹",
                InitialDirectory = Directory.Exists(_currentDirectory)
                    ? _currentDirectory
                    : _recentFolders.Paths.FirstOrDefault(Directory.Exists)
                        ?? Environment.GetFolderPath(Environment.SpecialFolder.MyPictures)
            };
            if (dialog.ShowDialog() == true) _ = OpenDirectoryAsync(dialog.FolderName);
        }

        private void BtnRefresh_Click(object sender, RoutedEventArgs e)
        {
            if (Directory.Exists(_currentDirectory)) _ = OpenDirectoryAsync(_currentDirectory, remember: false);
        }

        private void IncludeSubfoldersCheckBox_Click(object sender, RoutedEventArgs e)
        {
            if (!Directory.Exists(_currentDirectory)) return;
            _focusedPhotoId = null;
            _previousFocusedPhotoId = null;
            _selectedTag = null;
            LibraryPathText.Text = _browsingDirectory;
            RenderGallery();
            SetStatus(CurrentScopeSummary());
        }

        private void DirectoryTreeView_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
        {
            if (_suppressDirectorySelection || e.NewValue is not DirectoryNode node || !Directory.Exists(node.FullPath)) return;
            _browsingDirectory = Path.GetFullPath(node.FullPath);
            _focusedPhotoId = null;
            _previousFocusedPhotoId = null;
            _selectedTag = null;
            LibraryPathText.Text = _browsingDirectory;
            RenderGallery();
            SetStatus(CurrentScopeSummary());
        }

        private void BtnRecentFolders_Click(object sender, RoutedEventArgs e)
        {
            _recentFolders.RemoveUnavailable();
            var menu = new ContextMenu();
            foreach (string path in _recentFolders.Paths)
            {
                var item = new MenuItem
                {
                    Header = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar)) is { Length: > 0 } name ? name : path,
                    ToolTip = path,
                    IsEnabled = Directory.Exists(path)
                };
                item.Click += (_, _) => _ = OpenDirectoryAsync(path);
                menu.Items.Add(item);
            }
            if (menu.Items.Count > 0) menu.Items.Add(new Separator());
            var clear = new MenuItem { Header = "清空历史目录" };
            clear.Click += (_, _) => _recentFolders.Clear();
            menu.Items.Add(clear);
            menu.PlacementTarget = sender as Button;
            menu.IsOpen = true;
        }

        private async Task OpenDirectoryAsync(string path, bool remember = true)
        {
            if (!Directory.Exists(path))
            {
                SetStatus($"打不开目录：{path}");
                return;
            }

            _loadCts?.Cancel();
            _loadCts = new CancellationTokenSource();
            CancellationToken token = _loadCts.Token;
            if (ViewerMode.Visibility == Visibility.Visible)
            {
                StopMediaPlayback();
                ViewerMode.Visibility = Visibility.Collapsed;
                GridMode.Visibility = Visibility.Visible;
            }
            _currentDirectory = NormalizeDirectoryPath(path);
            _browsingDirectory = _currentDirectory;
            if (remember) _recentFolders.Add(_currentDirectory);
            _focusedPhotoId = null;
            _previousFocusedPhotoId = null;
            _selectedTag = null;
            _cardMap.Clear();
            _thumbnailMap.Clear();
            ThumbnailPanel.Children.Clear();
            CurrentPathText.Text = _currentDirectory;
            LibraryPathText.Text = _currentDirectory;
            SetStatus("正在扫描照片与视频…");
            SetWorking(true, 0, 1);

            try
            {
                const bool recursively = true;
                var files = await Task.Run(() => EnumerateMediaFiles(_currentDirectory, recursively, token), token);
                token.ThrowIfCancellationRequested();
                var imagePaths = files.Where(LivePhotoExtractor.IsSupportedImage).ToList();
                var videoPaths = files.Where(LivePhotoExtractor.IsSupportedVideo).ToList();
                var companions = await Task.Run(
                    () => LivePhotoExtractor.ResolveCompanionVideos(imagePaths, videoPaths), token);
                var pairedVideos = companions.Values.ToHashSet(StringComparer.OrdinalIgnoreCase);
                var index = await Task.Run(() => _libraryIndex.Load(_currentDirectory, recursively), token);

                _photos = imagePaths.Select(imagePath => CreatePhotoItem(
                        imagePath,
                        MediaKind.Image,
                        companions.GetValueOrDefault(imagePath)))
                    .Concat(videoPaths
                        .Where(videoPath => !pairedVideos.Contains(videoPath))
                        .Select(videoPath => CreatePhotoItem(videoPath, MediaKind.Video, null)))
                    .ToList();

                foreach (PhotoItem photo in _photos)
                {
                    photo.IsFavorite = _favoriteStore.IsFavorite(photo.Directory, photo.FileName);
                    photo.Tags = _tagStore.GetTags(photo.Directory, photo.FileName);
                    photo.HoldFrameTime = _holdFrameStore.Get(photo.FilePath);
                    if (index.TryGetValue(photo.FilePath, out LibraryIndexEntry? entry) && entry.Matches(photo))
                        entry.Apply(photo);
                    if (!string.IsNullOrWhiteSpace(photo.CompanionVideoPath))
                    {
                        photo.IsLivePhoto = true;
                        photo.LivePhotoSource = LivePhotoSource.AppleSidecar;
                        photo.IsLiveStatusKnown = true;
                    }
                    if (photo.IsVideo)
                    {
                        photo.IsLiveStatusKnown = true;
                        photo.IsMetadataLoaded = true;
                    }
                }

                BuildDirectoryTree();

                RenderGallery();
                SetStatus($"已发现 {_photos.Count} 个媒体文件，正在识别实况并生成缩略图…");
                await LoadThumbnailsAndDetectLiveAsync(token, recursively);
                token.ThrowIfCancellationRequested();
                RenderGallery();
                SetStatus(CurrentScopeSummary());
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                SetStatus($"加载失败：{ex.Message}");
            }
            finally
            {
                if (_loadCts?.Token == token) SetWorking(false);
            }
        }

        private PhotoItem CreatePhotoItem(string path, MediaKind kind, string? companion)
        {
            var info = new FileInfo(path);
            return new PhotoItem
            {
                FilePath = path,
                FileName = Path.GetFileName(path),
                Directory = Path.GetDirectoryName(path) ?? _currentDirectory,
                CompanionVideoPath = companion,
                MediaKind = kind,
                FileSize = info.Exists ? info.Length : 0,
                ModifiedAt = info.Exists ? info.LastWriteTime : DateTime.MinValue,
                TimelineDate = info.Exists ? info.LastWriteTime : DateTime.MinValue
            };
        }

        private static List<string> EnumerateMediaFiles(string root, bool recursively, CancellationToken token)
        {
            var result = new List<string>();
            var pending = new Stack<string>();
            pending.Push(root);
            while (pending.Count > 0)
            {
                token.ThrowIfCancellationRequested();
                string directory = pending.Pop();
                try
                {
                    foreach (string file in Directory.EnumerateFiles(directory))
                    {
                        token.ThrowIfCancellationRequested();
                        if (LivePhotoExtractor.IsSupportedImage(file) || LivePhotoExtractor.IsSupportedVideo(file))
                            result.Add(file);
                    }
                    if (!recursively) continue;
                    foreach (string child in Directory.EnumerateDirectories(directory))
                    {
                        try
                        {
                            var childInfo = new DirectoryInfo(child);
                            if (childInfo.Name.Equals(".MotionAlbumTrash", StringComparison.OrdinalIgnoreCase)) continue;
                            if ((childInfo.Attributes & FileAttributes.ReparsePoint) == 0)
                                pending.Push(child);
                        }
                        catch { }
                    }
                }
                catch { }
            }
            return result;
        }

        private IEnumerable<PhotoItem> ScopedPhotos()
        {
            if (string.IsNullOrWhiteSpace(_browsingDirectory)) return _photos;
            bool includeDescendants = IncludeSubfoldersCheckBox.IsChecked == true;
            return _photos.Where(photo => includeDescendants
                ? IsSameOrDescendant(photo.Directory, _browsingDirectory)
                : string.Equals(
                    NormalizeDirectoryPath(photo.Directory),
                    NormalizeDirectoryPath(_browsingDirectory),
                    StringComparison.OrdinalIgnoreCase));
        }

        private void BuildDirectoryTree()
        {
            if (!Directory.Exists(_currentDirectory))
            {
                DirectoryTreeView.ItemsSource = null;
                return;
            }

            string rootPath = NormalizeDirectoryPath(_currentDirectory);
            var nodes = new Dictionary<string, DirectoryNode>(StringComparer.OrdinalIgnoreCase)
            {
                [rootPath] = new DirectoryNode
                {
                    Name = DirectoryName(rootPath),
                    FullPath = rootPath
                }
            };

            foreach (PhotoItem photo in _photos)
            {
                string directory = NormalizeDirectoryPath(photo.Directory);
                if (!IsSameOrDescendant(directory, rootPath)) continue;

                if (!nodes.TryGetValue(directory, out DirectoryNode? directNode))
                {
                    directNode = new DirectoryNode { Name = DirectoryName(directory), FullPath = directory };
                    nodes[directory] = directNode;
                }
                directNode.PhotoCount++;

                string cursor = directory;
                while (!string.Equals(cursor, rootPath, StringComparison.OrdinalIgnoreCase))
                {
                    DirectoryInfo? parent = Directory.GetParent(cursor);
                    if (parent == null || !IsSameOrDescendant(parent.FullName, rootPath)) break;
                    cursor = NormalizeDirectoryPath(parent.FullName);
                    if (!nodes.ContainsKey(cursor))
                    {
                        nodes[cursor] = new DirectoryNode { Name = DirectoryName(cursor), FullPath = cursor };
                    }
                }
            }

            foreach (DirectoryNode node in nodes.Values.Where(node =>
                         !string.Equals(node.FullPath, rootPath, StringComparison.OrdinalIgnoreCase)))
            {
                string? parentPath = Directory.GetParent(node.FullPath)?.FullName;
                if (parentPath != null) parentPath = NormalizeDirectoryPath(parentPath);
                if (parentPath != null && nodes.TryGetValue(parentPath, out DirectoryNode? parent))
                    parent.Children.Add(node);
            }
            SortDirectoryNodes(nodes[rootPath]);

            if (!nodes.ContainsKey(_browsingDirectory)) _browsingDirectory = rootPath;
            foreach (DirectoryNode node in nodes.Values)
            {
                node.IsSelected = string.Equals(node.FullPath, _browsingDirectory, StringComparison.OrdinalIgnoreCase);
                node.IsExpanded = string.Equals(node.FullPath, rootPath, StringComparison.OrdinalIgnoreCase)
                    || IsSameOrDescendant(_browsingDirectory, node.FullPath);
            }
            _suppressDirectorySelection = true;
            DirectoryTreeView.ItemsSource = new[] { nodes[rootPath] };
            _suppressDirectorySelection = false;
        }

        private static void SortDirectoryNodes(DirectoryNode node)
        {
            node.Children.Sort((left, right) =>
                StringComparer.CurrentCultureIgnoreCase.Compare(left.Name, right.Name));
            foreach (DirectoryNode child in node.Children) SortDirectoryNodes(child);
        }

        private static string DirectoryName(string path)
        {
            string name = Path.GetFileName(NormalizeDirectoryPath(path));
            return string.IsNullOrWhiteSpace(name) ? path : name;
        }

        private static string NormalizeDirectoryPath(string path) =>
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

        private static bool IsSameOrDescendant(string path, string ancestor)
        {
            string relative = Path.GetRelativePath(Path.GetFullPath(ancestor), Path.GetFullPath(path));
            if (relative == ".") return true;
            if (Path.IsPathRooted(relative) || relative == "..") return false;
            return !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal)
                && !relative.StartsWith(".." + Path.AltDirectorySeparatorChar, StringComparison.Ordinal);
        }

        private string CurrentScopeSummary()
        {
            List<PhotoItem> scope = ScopedPhotos().ToList();
            return $"当前目录 {scope.Count:N0} 个 · 实况 {scope.Count(photo => photo.IsLivePhoto):N0} 个 · 视频 {scope.Count(photo => photo.IsVideo):N0} 个 · 喜欢 {scope.Count(photo => photo.IsFavorite):N0} 个";
        }

        private async Task LoadThumbnailsAndDetectLiveAsync(CancellationToken token, bool recursively)
        {
            SetWorking(true, 0, Math.Max(1, _photos.Count));
            int completed = 0;
            var tasks = _photos.Select(async photo =>
            {
                await _thumbnailSemaphore.WaitAsync(token);
                try
                {
                    BitmapImage? bitmap = await Task.Run(() => LoadOrCreateThumbnail(photo.FilePath), token);
                    if (!photo.IsVideo && !photo.IsMetadataLoaded)
                    {
                        PhotoMetadataInfo metadata = await Task.Run(() => PhotoMetadataReader.Read(photo.FilePath), token);
                        if (metadata.PixelWidth > 0)
                        {
                            photo.Width = metadata.PixelWidth;
                            photo.Height = metadata.PixelHeight;
                        }
                        photo.CapturedAt = metadata.CapturedAt;
                        photo.TimelineDate = metadata.CapturedAt ?? photo.ModifiedAt;
                        photo.DeviceText = metadata.DeviceText;
                        photo.Software = metadata.Software ?? string.Empty;
                        photo.Latitude = metadata.Latitude;
                        photo.Longitude = metadata.Longitude;
                        photo.IsMetadataLoaded = true;
                    }
                    if (!photo.IsVideo && !photo.IsLiveStatusKnown)
                    {
                        EmbeddedVideoRange? detectedRange = await Task.Run(() =>
                        {
                            return LivePhotoExtractor.TryGetEmbeddedVideoRange(photo.FilePath, out var range)
                                ? (EmbeddedVideoRange?)range : null;
                        }, token);
                        if (detectedRange is EmbeddedVideoRange range)
                        {
                            photo.IsLivePhoto = true;
                            photo.LivePhotoSource = range.Source;
                        }
                        photo.IsLiveStatusKnown = true;
                    }

                    int now = Interlocked.Increment(ref completed);
                    await Dispatcher.InvokeAsync(() =>
                    {
                        if (token.IsCancellationRequested) return;
                        _thumbnailMap[photo.StableId] = bitmap;
                        if (_cardMap.TryGetValue(photo.StableId, out var card))
                        {
                            card.SetLoaded(bitmap, photo.IsLivePhoto);
                            card.SetTags(photo.Tags);
                            card.SetDisplaySize(EffectiveCardWidth(), IsShowcaseMode);
                        }
                        WorkProgressBar.Value = now;
                        if (now % 24 == 0 || now == _photos.Count)
                        {
                            UpdateCounts();
                            SetStatus($"正在处理 {now}/{_photos.Count}…");
                        }
                    });
                }
                catch (OperationCanceledException) { }
                catch { }
                finally { _thumbnailSemaphore.Release(); }
            }).ToArray();

            await Task.WhenAll(tasks);
            await Task.Run(() => _libraryIndex.Save(_currentDirectory, recursively, _photos), token);
        }

        private static BitmapImage? LoadOrCreateThumbnail(string path)
        {
            try
            {
                string? cached = ThumbnailCache.GetThumbnailPath(path);
                if (cached != null) return LoadBitmap(cached, 700);
                byte[]? bytes = ThumbnailCache.GenerateThumbnailBytes(path, 700);
                if (bytes != null)
                {
                    ThumbnailCache.SaveThumbnail(path, bytes);
                    return LoadBitmapFromBytes(bytes);
                }
                return LoadBitmap(path, 700);
            }
            catch { return null; }
        }

        private static BitmapImage? LoadBitmap(string path, int decodePixelWidth = 2400)
        {
            try
            {
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.DecodePixelWidth = decodePixelWidth;
                image.UriSource = new Uri(path, UriKind.Absolute);
                image.EndInit();
                image.Freeze();
                return image;
            }
            catch { return null; }
        }

        private static BitmapImage? LoadBitmapFromBytes(byte[] bytes)
        {
            try
            {
                using var stream = new MemoryStream(bytes);
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.StreamSource = stream;
                image.EndInit();
                image.Freeze();
                return image;
            }
            catch { return null; }
        }

        // MARK: - Gallery rendering and interaction

        private void RenderGallery()
        {
            if (!IsLoaded) return;
            _visiblePhotos = ApplyFilterAndSort().ToList();
            ThumbnailPanel.Children.Clear();
            double cardWidth = EffectiveCardWidth();
            string groupingFormat = _galleryCardSize < 150 ? "yyyy年M月" : "yyyy年M月d日";
            var groups = _groupByTime
                ? _visiblePhotos.GroupBy(photo => photo.TimelineDate.ToString(groupingFormat))
                    .Select(group => (Label: group.Key, Items: group.ToList())).ToList()
                : new List<(string Label, List<PhotoItem> Items)> { (string.Empty, _visiblePhotos) };

            foreach (var group in groups)
            {
                if (_groupByTime)
                {
                    var header = new DockPanel { Margin = new Thickness(2, 4, 2, 8), LastChildFill = true };
                    header.Children.Add(new TextBlock
                    {
                        Text = group.Label,
                        FontSize = IsShowcaseMode ? 18 : 16,
                        FontWeight = FontWeights.SemiBold,
                        VerticalAlignment = VerticalAlignment.Center
                    });
                    header.Children.Add(new TextBlock
                    {
                        Text = $"  {group.Items.Count}",
                        FontSize = 11,
                        Foreground = (Brush)FindResource("SubTextBrush"),
                        VerticalAlignment = VerticalAlignment.Center
                    });
                    header.Children.Add(new Border
                    {
                        Height = 1,
                        Margin = new Thickness(10, 0, 0, 0),
                        Background = (Brush)FindResource("BorderBrush"),
                        VerticalAlignment = VerticalAlignment.Center
                    });
                    ThumbnailPanel.Children.Add(header);
                }

                var panel = new WrapPanel
                {
                    Orientation = Orientation.Horizontal,
                    HorizontalAlignment = IsShowcaseMode ? HorizontalAlignment.Center : HorizontalAlignment.Stretch,
                    Margin = new Thickness(0, 0, 0, IsShowcaseMode ? 18 : 12)
                };
                if (IsShowcaseMode) panel.Width = cardWidth + 12;
                foreach (PhotoItem photo in group.Items)
                {
                    if (!_cardMap.TryGetValue(photo.StableId, out var card))
                    {
                        bool thumbnailReady = _thumbnailMap.TryGetValue(photo.StableId, out BitmapImage? thumbnail);
                        card = new ThumbnailCard(photo, isLoading: !thumbnailReady);
                        card.PhotoFocused += OnThumbnailFocused;
                        card.PhotoOpened += OnThumbnailOpened;
                        card.FavoriteToggled += OnFavoriteToggled;
                        card.RevealRequested += OnRevealRequested;
                        card.TrashRequested += OnTrashRequested;
                        _cardMap[photo.StableId] = card;
                        if (thumbnailReady) card.SetLoaded(thumbnail, photo.IsLivePhoto);
                    }
                    card.Margin = new Thickness(IsShowcaseMode ? 4 : 4, 0, 4, IsShowcaseMode ? 18 : 8);
                    card.SetDisplaySize(cardWidth, IsShowcaseMode);
                    card.SetFocused(string.Equals(photo.StableId, _focusedPhotoId, StringComparison.OrdinalIgnoreCase));
                    panel.Children.Add(card);
                }
                ThumbnailPanel.Children.Add(panel);
            }
            UpdateCounts();
            VisibleCountText.Text = $"当前显示 {_visiblePhotos.Count:N0} 个";
            ScheduleShowcasePreviewRefresh();
        }

        private void GalleryScrollViewer_ScrollChanged(object sender, ScrollChangedEventArgs e)
        {
            if (IsShowcaseMode) ScheduleShowcasePreviewRefresh();
        }

        private async void ScheduleShowcasePreviewRefresh()
        {
            _showcasePreviewCts?.Cancel();
            _showcasePreviewCts = new CancellationTokenSource();
            CancellationToken token = _showcasePreviewCts.Token;
            if (!IsShowcaseMode)
            {
                foreach (ThumbnailCard card in _cardMap.Values) card.SetHighResolutionPreview(false);
                return;
            }
            try { await Task.Delay(100, token); }
            catch (OperationCanceledException) { return; }
            if (token.IsCancellationRequested || !IsShowcaseMode) return;

            var viewport = new Rect(-80, -240, GalleryScrollViewer.ActualWidth + 160, GalleryScrollViewer.ActualHeight + 480);
            foreach (ThumbnailCard card in _cardMap.Values)
            {
                bool isNearViewport = false;
                try
                {
                    Point origin = card.TranslatePoint(new Point(0, 0), GalleryScrollViewer);
                    isNearViewport = viewport.IntersectsWith(new Rect(origin, card.RenderSize));
                }
                catch { }
                card.SetHighResolutionPreview(isNearViewport);
            }
        }

        private IEnumerable<PhotoItem> ApplyFilterAndSort()
        {
            IEnumerable<PhotoItem> query = ScopedPhotos();
            query = _filter switch
            {
                LibraryFilter.Live => query.Where(photo => photo.IsLivePhoto),
                LibraryFilter.Video => query.Where(photo => photo.IsVideo),
                LibraryFilter.Favorite => query.Where(photo => photo.IsFavorite),
                _ => query
            };
            if (!string.IsNullOrWhiteSpace(_selectedTag))
                query = query.Where(photo => photo.Tags.Contains(_selectedTag, StringComparer.CurrentCultureIgnoreCase));
            string search = SearchBox.Text.Trim();
            if (search.Length > 0)
            {
                string[] terms = search.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                query = query.Where(photo => terms.All(term => MatchesSearch(photo, term)));
            }
            string sort = (SortComboBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "Newest";
            return sort switch
            {
                "Oldest" => query.OrderBy(photo => photo.TimelineDate)
                    .ThenBy(photo => photo.FileName, StringComparer.CurrentCultureIgnoreCase),
                "Modified" => query.OrderByDescending(photo => photo.ModifiedAt)
                    .ThenBy(photo => photo.FileName, StringComparer.CurrentCultureIgnoreCase),
                "Name" => query.OrderBy(photo => photo.FileName, StringComparer.CurrentCultureIgnoreCase),
                _ => query.OrderByDescending(photo => photo.TimelineDate)
                    .ThenBy(photo => photo.FileName, StringComparer.CurrentCultureIgnoreCase)
            };
        }

        private static bool MatchesSearch(PhotoItem photo, string term) =>
            photo.FileName.Contains(term, StringComparison.OrdinalIgnoreCase) ||
            photo.Directory.Contains(term, StringComparison.OrdinalIgnoreCase) ||
            photo.DeviceText.Contains(term, StringComparison.OrdinalIgnoreCase) ||
            photo.Software.Contains(term, StringComparison.OrdinalIgnoreCase) ||
            photo.PlaceName.Contains(term, StringComparison.OrdinalIgnoreCase) ||
            photo.CoordinateText.Contains(term, StringComparison.OrdinalIgnoreCase) ||
            photo.Tags.Any(tag => tag.Contains(term, StringComparison.OrdinalIgnoreCase));

        private double EffectiveCardWidth()
        {
            if (!IsShowcaseMode) return _galleryCardSize;
            double available = Math.Max(320, GalleryScrollViewer.ViewportWidth - 72);
            return Math.Min(_galleryCardSize, Math.Min(1100, available));
        }

        private void OnThumbnailFocused(object? sender, string filePath)
        {
            PhotoItem? photo = _photos.FirstOrDefault(item =>
                string.Equals(item.FilePath, filePath, StringComparison.OrdinalIgnoreCase));
            if (photo != null) SetFocusedPhoto(photo);
        }

        private void OnThumbnailOpened(object? sender, string filePath)
        {
            int index = _visiblePhotos.FindIndex(photo =>
                string.Equals(photo.FilePath, filePath, StringComparison.OrdinalIgnoreCase));
            if (index >= 0) EnterViewerMode(index);
        }

        private void SetFocusedPhoto(PhotoItem photo)
        {
            if (string.Equals(_focusedPhotoId, photo.StableId, StringComparison.OrdinalIgnoreCase)) return;
            if (!string.IsNullOrWhiteSpace(_focusedPhotoId)) _previousFocusedPhotoId = _focusedPhotoId;
            _focusedPhotoId = photo.StableId;
            foreach (var pair in _cardMap)
                pair.Value.SetFocused(string.Equals(pair.Key, _focusedPhotoId, StringComparison.OrdinalIgnoreCase));
            BtnReturnCurrent.Visibility = Visibility.Visible;
            BtnReturnPrevious.Visibility = string.IsNullOrWhiteSpace(_previousFocusedPhotoId)
                ? Visibility.Collapsed : Visibility.Visible;
        }

        private void OnFavoriteToggled(object? sender, string filePath)
        {
            PhotoItem? photo = _photos.FirstOrDefault(item =>
                string.Equals(item.FilePath, filePath, StringComparison.OrdinalIgnoreCase));
            if (photo == null) return;
            _favoriteStore.SetFavorite(photo.Directory, photo.FileName, photo.IsFavorite);
            SetStatus(photo.IsFavorite ? $"已加入我喜欢：{photo.FileName}" : $"已取消喜欢：{photo.FileName}");
            if (_filter == LibraryFilter.Favorite && !photo.IsFavorite) RenderGallery();
            else UpdateCounts();
            UpdateViewerFavoriteButton();
        }

        private void OnRevealRequested(object? sender, string filePath)
        {
            try
            {
                var startInfo = new ProcessStartInfo("explorer.exe") { UseShellExecute = true };
                startInfo.ArgumentList.Add($"/select,{filePath}");
                Process.Start(startInfo);
            }
            catch (Exception ex) { SetStatus($"无法在资源管理器中显示：{ex.Message}"); }
        }

        private async void OnTrashRequested(object? sender, string filePath)
        {
            PhotoItem? photo = _photos.FirstOrDefault(item =>
                string.Equals(item.FilePath, filePath, StringComparison.OrdinalIgnoreCase));
            if (photo != null) await ConfirmAndTrashAsync(new List<PhotoItem> { photo });
        }

        private void FilterButton_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button button || button.Tag is not string value) return;
            _filter = Enum.TryParse(value, out LibraryFilter parsed) ? parsed : LibraryFilter.All;
            _selectedTag = null;
            UpdateFilterVisuals();
            RenderGallery();
        }

        private void UpdateFilterVisuals()
        {
            var buttons = new Dictionary<LibraryFilter, Button>
            {
                [LibraryFilter.All] = BtnFilterAll,
                [LibraryFilter.Live] = BtnFilterLive,
                [LibraryFilter.Video] = BtnFilterVideo,
                [LibraryFilter.Favorite] = BtnFilterFavorite
            };
            foreach (var pair in buttons)
                pair.Value.Background = pair.Key == _filter
                    ? new SolidColorBrush(Color.FromArgb(48, 59, 130, 246))
                    : Brushes.Transparent;
            UpdateTagSidebarSelection();
        }

        private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            SearchHintText.Visibility = string.IsNullOrEmpty(SearchBox.Text)
                ? Visibility.Visible : Visibility.Collapsed;
            if (IsLoaded) RenderGallery();
        }

        private void SortComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (IsLoaded) RenderGallery();
        }

        private void GroupByTimeCheckBox_Click(object sender, RoutedEventArgs e)
        {
            _groupByTime = GroupByTimeCheckBox.IsChecked == true;
            RenderGallery();
        }

        private void BtnReturnCurrent_Click(object sender, RoutedEventArgs e) => ScrollToPhoto(_focusedPhotoId);

        private void BtnReturnPrevious_Click(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(_previousFocusedPhotoId)) return;
            string target = _previousFocusedPhotoId;
            _previousFocusedPhotoId = _focusedPhotoId;
            _focusedPhotoId = target;
            foreach (var pair in _cardMap)
                pair.Value.SetFocused(string.Equals(pair.Key, _focusedPhotoId, StringComparison.OrdinalIgnoreCase));
            ScrollToPhoto(_focusedPhotoId);
        }

        private void ScrollToPhoto(string? stableId)
        {
            if (stableId != null && _cardMap.TryGetValue(stableId, out var card)) card.BringIntoView();
            else SetStatus("这张照片不在当前筛选结果中");
        }

        private void BtnScrollTop_Click(object sender, RoutedEventArgs e) => GalleryScrollViewer.ScrollToTop();

        // MARK: - Gallery zoom

        private void GalleryZoomSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_suppressGalleryZoomEvent) return;
            _galleryCardSize = SizeForZoomPosition(e.NewValue);
            if (IsLoaded) RenderGallery();
        }

        private void GalleryZoomOut_Click(object sender, RoutedEventArgs e) => StepGalleryZoom(-1);
        private void GalleryZoomIn_Click(object sender, RoutedEventArgs e) => StepGalleryZoom(1);

        private void StepGalleryZoom(int direction)
        {
            const double tolerance = 0.5;
            double target = direction < 0
                ? _galleryZoomStops.LastOrDefault(value => value < _galleryCardSize - tolerance)
                : _galleryZoomStops.FirstOrDefault(value => value > _galleryCardSize + tolerance);
            if (target <= 0) target = direction < 0 ? _galleryZoomStops[0] : _galleryZoomStops[^1];
            SetGalleryCardSize(target);
        }

        private void SetGalleryCardSize(double size)
        {
            _galleryCardSize = Math.Clamp(size, _galleryZoomStops[0], _galleryZoomStops[^1]);
            _suppressGalleryZoomEvent = true;
            GalleryZoomSlider.Value = ZoomPositionForSize(_galleryCardSize);
            _suppressGalleryZoomEvent = false;
            RenderGallery();
        }

        private static double SizeForZoomPosition(double position)
        {
            const double lower = 72;
            const double upper = 1100;
            return lower * Math.Pow(upper / lower, Math.Clamp(position, 0, 1));
        }

        private static double ZoomPositionForSize(double size)
        {
            const double lower = 72;
            const double upper = 1100;
            return Math.Log(Math.Clamp(size, lower, upper) / lower) / Math.Log(upper / lower);
        }

        private void GalleryScrollViewer_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
        {
            if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
            SetGalleryCardSize(SizeForZoomPosition(GalleryZoomSlider.Value + (e.Delta > 0 ? 0.045 : -0.045)));
            e.Handled = true;
        }

        private void GalleryScrollViewer_ManipulationStarting(object sender, ManipulationStartingEventArgs e)
        {
            _galleryManipulationBaseSize = _galleryCardSize;
            e.Mode = ManipulationModes.Scale | ManipulationModes.TranslateY;
        }

        private void GalleryScrollViewer_ManipulationDelta(object sender, ManipulationDeltaEventArgs e)
        {
            double scale = e.CumulativeManipulation.Scale.X;
            if (double.IsFinite(scale) && scale > 0 && Math.Abs(scale - 1) > 0.004)
            {
                SetGalleryCardSize(_galleryManipulationBaseSize * scale);
                e.Handled = true;
            }
        }

        // MARK: - Viewer

        private void EnterViewerMode(int index)
        {
            if (index < 0 || index >= _visiblePhotos.Count) return;
            _viewerIndex = index;
            SetFocusedPhoto(_visiblePhotos[index]);
            GridMode.Visibility = Visibility.Collapsed;
            ViewerMode.Visibility = Visibility.Visible;
            LoadViewerPhoto(index);
            QueueAutoPlay();
        }

        private void ExitViewerMode()
        {
            StopMediaPlayback();
            ResetViewerTransform();
            ViewerMode.Visibility = Visibility.Collapsed;
            GridMode.Visibility = Visibility.Visible;
            RenderGallery();
            Dispatcher.BeginInvoke(new Action(() => ScrollToPhoto(_focusedPhotoId)));
        }

        private void LoadViewerPhoto(int index)
        {
            if (index < 0 || index >= _visiblePhotos.Count) return;
            StopMediaPlayback();
            PhotoItem photo = _visiblePhotos[index];
            _viewerIndex = index;
            SetFocusedPhoto(photo);
            ResetViewerTransform();

            ViewerImage.Source = photo.IsVideo
                ? LoadOrCreateThumbnail(photo.FilePath)
                : LoadBitmap(photo.FilePath, 3200);
            ViewerImage.Visibility = Visibility.Visible;
            ViewerVideoView.Visibility = Visibility.Collapsed;
            BtnViewerPlay.Visibility = photo.IsLivePhoto || photo.IsVideo ? Visibility.Visible : Visibility.Collapsed;
            BtnViewerPlay.IsEnabled = true;
            BtnViewerEditCover.Visibility = photo.IsLivePhoto || photo.IsVideo ? Visibility.Visible : Visibility.Collapsed;
            BtnViewerPlay.Content = photo.IsVideo ? "▶  播放视频" : "▶  播放实况";
            string capturedAt = photo.CapturedAt is DateTime date ? $"  ·  {date:yyyy-MM-dd HH:mm:ss}" : string.Empty;
            string device = photo.DeviceText.Length > 0 ? $"  ·  {photo.DeviceText}" : string.Empty;
            string software = photo.Software.Length > 0 ? $"  ·  {photo.Software}" : string.Empty;
            string location = photo.CoordinateText.Length > 0 ? $"  ·  {photo.CoordinateText}" : string.Empty;
            ViewerInfoText.Text = $"{photo.FileName}  ·  {(photo.Width > 0 ? $"{photo.Width} × {photo.Height}  ·  " : string.Empty)}{FormatBytes(photo.FileSize)}{capturedAt}{device}{software}{location}  ·  {(photo.IsLivePhoto ? "实况照片" : photo.IsVideo ? "视频" : "照片")}";
            BtnViewerPrevious.IsEnabled = index > 0;
            BtnViewerNext.IsEnabled = index + 1 < _visiblePhotos.Count;
            LeftNavZone.IsEnabled = BtnViewerPrevious.IsEnabled;
            RightNavZone.IsEnabled = BtnViewerNext.IsEnabled;
            CoverFrameEditor.Visibility = Visibility.Collapsed;
            _isEditingCoverFrame = false;
            UpdateViewerZoomControls();
            UpdateViewerFavoriteButton();
            UpdateViewerTags(photo);
        }

        private async void ViewerPlay_Click(object sender, RoutedEventArgs e)
        {
            if (ViewerVideoView.Visibility == Visibility.Visible) { StopMediaPlayback(); return; }
            await PlayCurrentMediaAsync();
        }

        private async Task PlayCurrentMediaAsync()
        {
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            if (_libVlc == null)
            {
                try { _libVlc = new LibVLC("--quiet", "--no-video-title-show", "--intf=dummy"); }
                catch (Exception ex) { SetStatus($"播放器初始化失败：{ex.Message}"); return; }
            }
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            int requestedIndex = _viewerIndex;
            SetStatus("正在准备视频…");
            string? path = await Task.Run(() => photo.IsVideo
                ? photo.FilePath
                : LivePhotoExtractor.GetPlayableVideoPath(photo.FilePath, photo.CompanionVideoPath));
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                SetStatus("没有找到可播放的实况视频");
                return;
            }
            if (requestedIndex != _viewerIndex || ViewerMode.Visibility != Visibility.Visible) return;
            EnsureMediaPlayer();
            _currentVlcMedia?.Dispose();
            _currentVlcMedia = new VlcMedia(_libVlc, new Uri(path));
            _mediaSessionId++;
            ViewerImage.Visibility = Visibility.Collapsed;
            ViewerVideoView.Visibility = Visibility.Visible;
            UpdateViewerZoomControls();
            _mediaPlayer!.Play(_currentVlcMedia);
            BtnViewerPlay.Content = photo.IsVideo ? "▣  显示封面" : "▣  显示照片";
        }

        private void EnsureMediaPlayer()
        {
            if (_mediaPlayer != null) return;
            _mediaPlayer = new VlcMediaPlayer(_libVlc!);
            ViewerVideoView.MediaPlayer = _mediaPlayer;
            _mediaPlayer.EndReached += (_, _) =>
            {
                int endedSession = _mediaSessionId;
                Dispatcher.BeginInvoke(new Action(async () => await FinishMediaPlaybackAsync(endedSession)));
            };
        }

        private void StopMediaPlayback()
        {
            _mediaSessionId++;
            try { _mediaPlayer?.Stop(); } catch { }
            _currentVlcMedia?.Dispose();
            _currentVlcMedia = null;
            ViewerVideoView.Visibility = Visibility.Collapsed;
            if (_viewerIndex >= 0 && _viewerIndex < _visiblePhotos.Count)
            {
                PhotoItem photo = _visiblePhotos[_viewerIndex];
                ViewerImage.Visibility = Visibility.Visible;
                BtnViewerPlay.Content = photo.IsVideo ? "▶  播放视频" : "▶  播放实况";
            }
            UpdateViewerZoomControls();
        }

        private async Task FinishMediaPlaybackAsync(int endedSession)
        {
            if (endedSession != _mediaSessionId) return;
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) { StopMediaPlayback(); return; }
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            if (photo.HoldFrameTime is not double seconds || _mediaPlayer == null || _currentVlcMedia == null)
            {
                StopMediaPlayback();
                return;
            }
            try
            {
                _mediaSessionId++;
                _mediaPlayer.Play();
                await Task.Delay(120);
                long maximum = _mediaPlayer.Length > 0 ? _mediaPlayer.Length : long.MaxValue;
                _mediaPlayer.Time = Math.Clamp((long)(seconds * 1000), 0, maximum);
                await Task.Delay(40);
                _mediaPlayer.SetPause(true);
                ViewerImage.Visibility = Visibility.Collapsed;
                ViewerVideoView.Visibility = Visibility.Visible;
                BtnViewerPlay.Content = photo.IsVideo ? "▣  显示封面" : "▣  显示照片";
                UpdateViewerZoomControls();
            }
            catch { StopMediaPlayback(); }
        }

        private void ViewerPrev_Click(object sender, RoutedEventArgs e) => NavigateViewer(-1);
        private void ViewerNext_Click(object sender, RoutedEventArgs e) => NavigateViewer(1);

        private void NavigateViewer(int offset)
        {
            int target = _viewerIndex + offset;
            if (target < 0 || target >= _visiblePhotos.Count) return;
            LoadViewerPhoto(target);
            QueueAutoPlay();
        }

        private void QueueAutoPlay()
        {
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            if (!photo.IsLivePhoto && !photo.IsVideo) return;
            int requestedIndex = _viewerIndex;
            Dispatcher.BeginInvoke(new Action(async () =>
            {
                if (requestedIndex == _viewerIndex && ViewerMode.Visibility == Visibility.Visible)
                    await PlayCurrentMediaAsync();
            }));
        }

        private void ViewerClose_Click(object sender, RoutedEventArgs e) => ExitViewerMode();

        private void ViewerFav_Click(object sender, RoutedEventArgs e)
        {
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            photo.IsFavorite = !photo.IsFavorite;
            _favoriteStore.SetFavorite(photo.Directory, photo.FileName, photo.IsFavorite);
            if (_cardMap.TryGetValue(photo.StableId, out var card)) card.IsFavorite = photo.IsFavorite;
            UpdateViewerFavoriteButton();
            UpdateCounts();
        }

        private void UpdateViewerFavoriteButton()
        {
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            BtnViewerFavorite.Content = _visiblePhotos[_viewerIndex].IsFavorite ? "♥  我喜欢" : "♡  我喜欢";
            BtnViewerFavorite.Foreground = _visiblePhotos[_viewerIndex].IsFavorite ? Brushes.Red : (Brush)FindResource("TextBrush");
        }

        private void ViewerZoomOut_Click(object sender, RoutedEventArgs e) => SetViewerScale(_viewerScale / 1.2);
        private void ViewerZoomIn_Click(object sender, RoutedEventArgs e) => SetViewerScale(_viewerScale * 1.2);
        private void ViewerResetZoom_Click(object sender, RoutedEventArgs e) => ResetViewerTransform();

        private void SetViewerScale(double scale)
        {
            if (ViewerVideoView.Visibility == Visibility.Visible) return;
            _viewerScale = Math.Clamp(scale, 0.1, 5);
            ViewerScaleTransform.ScaleX = _viewerScale;
            ViewerScaleTransform.ScaleY = _viewerScale;
            BtnViewerZoomPercent.Content = $"{_viewerScale * 100:F0}%";
            bool zoomed = _viewerScale > 1.01;
            LeftNavZone.Visibility = zoomed ? Visibility.Collapsed : Visibility.Visible;
            RightNavZone.Visibility = zoomed ? Visibility.Collapsed : Visibility.Visible;
            UpdateViewerZoomControls();
        }

        private void ResetViewerTransform()
        {
            _viewerScale = 1;
            _isDraggingViewer = false;
            ViewerScaleTransform.ScaleX = 1;
            ViewerScaleTransform.ScaleY = 1;
            BtnViewerZoomPercent.Content = "100%";
            ViewerTranslateTransform.X = 0;
            ViewerTranslateTransform.Y = 0;
            LeftNavZone.Visibility = Visibility.Visible;
            RightNavZone.Visibility = Visibility.Visible;
            UpdateViewerZoomControls();
        }

        private void UpdateViewerZoomControls()
        {
            if (!IsLoaded) return;
            bool canZoom = ViewerVideoView.Visibility != Visibility.Visible;
            BtnViewerZoomOut.IsEnabled = canZoom && _viewerScale > 0.101;
            BtnViewerZoomIn.IsEnabled = canZoom && _viewerScale < 4.999;
            BtnViewerZoomPercent.IsEnabled = canZoom && Math.Abs(_viewerScale - 1) > 0.001;
        }

        private void ViewerImageContainer_MouseWheel(object sender, MouseWheelEventArgs e)
        {
            SetViewerScale(_viewerScale * (e.Delta > 0 ? 1.15 : 0.85));
            e.Handled = true;
        }

        private void ViewerImageContainer_ManipulationStarting(object sender, ManipulationStartingEventArgs e)
        {
            _viewerManipulationBaseScale = _viewerScale;
            e.Mode = ManipulationModes.Scale;
        }

        private void ViewerImageContainer_ManipulationDelta(object sender, ManipulationDeltaEventArgs e)
        {
            double scale = e.CumulativeManipulation.Scale.X;
            if (double.IsFinite(scale) && scale > 0) SetViewerScale(_viewerManipulationBaseScale * scale);
            e.Handled = true;
        }

        private void ViewerImageContainer_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            Point position = e.GetPosition(ViewerImageContainer);
            DateTime now = DateTime.Now;
            if ((now - _lastViewerClick).TotalMilliseconds < 300 &&
                Math.Abs(position.X - _lastViewerClickPosition.X) < 6 &&
                Math.Abs(position.Y - _lastViewerClickPosition.Y) < 6)
            {
                ResetViewerTransform();
                e.Handled = true;
                return;
            }
            _lastViewerClick = now;
            _lastViewerClickPosition = position;
            if (_viewerScale <= 1.01) return;
            _isDraggingViewer = true;
            _dragStart = position;
            _dragStartTranslation = new Point(ViewerTranslateTransform.X, ViewerTranslateTransform.Y);
            ViewerImageContainer.CaptureMouse();
            e.Handled = true;
        }

        private void ViewerImageContainer_MouseMove(object sender, MouseEventArgs e)
        {
            if (!_isDraggingViewer) return;
            Point current = e.GetPosition(ViewerImageContainer);
            ViewerTranslateTransform.X = _dragStartTranslation.X + current.X - _dragStart.X;
            ViewerTranslateTransform.Y = _dragStartTranslation.Y + current.Y - _dragStart.Y;
            e.Handled = true;
        }

        private void ViewerImageContainer_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (!_isDraggingViewer) return;
            _isDraggingViewer = false;
            ViewerImageContainer.ReleaseMouseCapture();
            e.Handled = true;
        }

        private async void ViewerEditCover_Click(object sender, RoutedEventArgs e)
        {
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            string requestedId = photo.StableId;
            StopMediaPlayback();
            string? path = await Task.Run(() => photo.IsVideo
                ? photo.FilePath
                : LivePhotoExtractor.GetPlayableVideoPath(photo.FilePath, photo.CompanionVideoPath));
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count ||
                !string.Equals(_visiblePhotos[_viewerIndex].StableId, requestedId, StringComparison.OrdinalIgnoreCase)) return;
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                SetStatus("没有找到可编辑的实况视频");
                return;
            }
            try
            {
                if (_libVlc == null) _libVlc = new LibVLC("--quiet", "--no-video-title-show", "--intf=dummy");
                EnsureMediaPlayer();
                _currentVlcMedia?.Dispose();
                _currentVlcMedia = new VlcMedia(_libVlc, new Uri(path));
                _mediaSessionId++;
                ViewerImage.Visibility = Visibility.Collapsed;
                ViewerVideoView.Visibility = Visibility.Visible;
                UpdateViewerZoomControls();
                _mediaPlayer!.Play(_currentVlcMedia);
                for (int attempt = 0; attempt < 20 && _mediaPlayer.Length <= 0; attempt++)
                    await Task.Delay(75);
                long duration = Math.Max(1, _mediaPlayer.Length);
                long position = (long)Math.Clamp((photo.HoldFrameTime ?? 0) * 1000, 0, duration);
                _suppressCoverSlider = true;
                CoverFrameSlider.Maximum = duration;
                CoverFrameSlider.Value = position;
                _suppressCoverSlider = false;
                _mediaPlayer.Time = position;
                await Task.Delay(40);
                _mediaPlayer.SetPause(true);
                _isEditingCoverFrame = true;
                CoverFrameEditor.Visibility = Visibility.Visible;
                BtnViewerPlay.IsEnabled = false;
                UpdateCoverFrameTime(position);
                BtnViewerPlay.Content = photo.IsVideo ? "▣  显示封面" : "▣  显示照片";
            }
            catch (Exception ex)
            {
                StopMediaPlayback();
                SetStatus($"停留画面编辑失败：{ex.Message}");
            }
        }

        private void CoverFrameSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_suppressCoverSlider || !_isEditingCoverFrame || _mediaPlayer == null) return;
            long milliseconds = (long)e.NewValue;
            try
            {
                _mediaPlayer.Time = milliseconds;
                _mediaPlayer.SetPause(true);
            }
            catch { }
            UpdateCoverFrameTime(milliseconds);
        }

        private void UpdateCoverFrameTime(long milliseconds)
        {
            TimeSpan time = TimeSpan.FromMilliseconds(Math.Max(0, milliseconds));
            CoverFrameTimeText.Text = $"{(int)time.TotalMinutes:00}:{time.Seconds:00}.{time.Milliseconds:000}";
        }

        private void CoverFrameApply_Click(object sender, RoutedEventArgs e)
        {
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            photo.HoldFrameTime = CoverFrameSlider.Value / 1000.0;
            _holdFrameStore.Set(photo.FilePath, photo.HoldFrameTime);
            _isEditingCoverFrame = false;
            CoverFrameEditor.Visibility = Visibility.Collapsed;
            BtnViewerPlay.IsEnabled = true;
            SetStatus($"已设置播放结束停留画面：{CoverFrameTimeText.Text}");
        }

        private void CoverFrameRestore_Click(object sender, RoutedEventArgs e)
        {
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            photo.HoldFrameTime = null;
            _holdFrameStore.Set(photo.FilePath, null);
            CoverFrameCancel_Click(sender, e);
            SetStatus("已恢复使用原始封面");
        }

        private void CoverFrameCancel_Click(object sender, RoutedEventArgs e)
        {
            _isEditingCoverFrame = false;
            CoverFrameEditor.Visibility = Visibility.Collapsed;
            BtnViewerPlay.IsEnabled = true;
            StopMediaPlayback();
        }

        private async void ViewerTrash_Click(object sender, RoutedEventArgs e)
        {
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            await ConfirmAndTrashAsync(new List<PhotoItem> { _visiblePhotos[_viewerIndex] });
        }

        // MARK: - Tags

        private void UpdateViewerTags(PhotoItem photo)
        {
            ViewerTagsPanel.Children.Clear();
            foreach (string tag in photo.Tags.ToList())
            {
                var remove = new Button
                {
                    Content = $"{tag}  ×",
                    Style = (Style)FindResource("FlatButtonStyle"),
                    Tag = tag,
                    Margin = new Thickness(0, 0, 6, 0)
                };
                remove.Click += async (_, _) =>
                {
                    await _tagStore.RemoveTagAsync(photo.Directory, photo.FileName, tag);
                    photo.Tags.Remove(tag);
                    if (_cardMap.TryGetValue(photo.StableId, out var card)) card.SetTags(photo.Tags);
                    UpdateViewerTags(photo);
                    UpdateCounts();
                    if (string.Equals(_selectedTag, tag, StringComparison.CurrentCultureIgnoreCase)) RenderGallery();
                };
                ViewerTagsPanel.Children.Add(remove);
            }
        }

        private void TagInputBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key != Key.Enter) return;
            AddTagFromInput();
            e.Handled = true;
        }

        private void BtnAddTag_Click(object sender, RoutedEventArgs e) => AddTagFromInput();

        private async void AddTagFromInput()
        {
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            string tag = TagInputBox.Text.Trim();
            if (tag.Length == 0) return;
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            await _tagStore.AddTagAsync(photo.Directory, photo.FileName, tag);
            if (!photo.Tags.Contains(tag)) photo.Tags.Add(tag);
            TagInputBox.Clear();
            if (_cardMap.TryGetValue(photo.StableId, out var card)) card.SetTags(photo.Tags);
            UpdateViewerTags(photo);
            UpdateCounts();
        }

        private void UpdateTagSidebar()
        {
            var tags = ScopedPhotos().SelectMany(photo => photo.Tags)
                .GroupBy(tag => tag, StringComparer.CurrentCultureIgnoreCase)
                .Select(group => (Name: group.Key, Count: group.Count()))
                .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
            if (_selectedTag != null && !tags.Any(item =>
                    string.Equals(item.Name, _selectedTag, StringComparison.CurrentCultureIgnoreCase)))
                _selectedTag = null;
            string signature = string.Join("|", tags.Select(item => $"{item.Name}:{item.Count}"));
            if (signature == _tagSidebarSignature)
            {
                UpdateTagSidebarSelection();
                return;
            }
            _tagSidebarSignature = signature;
            TagFilterPanel.Children.Clear();
            foreach (var tag in tags)
            {
                var name = new TextBlock { Text = $"◇  {tag.Name}", TextTrimming = TextTrimming.CharacterEllipsis };
                var count = new TextBlock
                {
                    Text = tag.Count.ToString("N0"),
                    Foreground = (Brush)FindResource("SubTextBrush")
                };
                var content = new DockPanel();
                DockPanel.SetDock(count, Dock.Right);
                content.Children.Add(count);
                content.Children.Add(name);
                var button = new Button
                {
                    Tag = tag.Name,
                    Content = content,
                    Style = (Style)FindResource("SidebarRowStyle")
                };
                button.Click += TagFilterButton_Click;
                TagFilterPanel.Children.Add(button);
            }
            TagFilterSeparator.Visibility = tags.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            UpdateTagSidebarSelection();
        }

        private void TagFilterButton_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button button || button.Tag is not string tag) return;
            _selectedTag = string.Equals(_selectedTag, tag, StringComparison.CurrentCultureIgnoreCase) ? null : tag;
            UpdateFilterVisuals();
            RenderGallery();
        }

        private void UpdateTagSidebarSelection()
        {
            foreach (Button button in TagFilterPanel.Children.OfType<Button>())
                button.Background = button.Tag is string tag &&
                    string.Equals(tag, _selectedTag, StringComparison.CurrentCultureIgnoreCase)
                        ? new SolidColorBrush(Color.FromArgb(48, 59, 130, 246))
                        : Brushes.Transparent;
        }

        // MARK: - Sidebar actions

        private void BtnToggleSidebar_Click(object sender, RoutedEventArgs e)
        {
            _isSidebarVisible = !_isSidebarVisible;
            _settings.SidebarVisible = _isSidebarVisible;
            ApplySidebarVisibility();
        }

        private void ApplySidebarVisibility()
        {
            SidebarColumn.Width = _isSidebarVisible ? new GridLength(246) : new GridLength(0);
            SidebarPanel.Visibility = _isSidebarVisible ? Visibility.Visible : Visibility.Collapsed;
        }

        private async void BtnExport_Click(object sender, RoutedEventArgs e)
        {
            if (_isWorking || _visiblePhotos.Count == 0) return;
            var dialog = new OpenFolderDialog { Title = "选择导出目录" };
            if (dialog.ShowDialog() != true) return;
            int copied = 0;
            SetStatus("正在导出…");
            var sources = _visiblePhotos.SelectMany(photo => photo.OriginalResourcePaths)
                .Distinct(StringComparer.OrdinalIgnoreCase).Where(File.Exists).ToList();
            SetWorking(true, 0, Math.Max(1, sources.Count));
            try
            {
                await Task.Run(() =>
                {
                    foreach (string source in sources)
                    {
                        string destination = UniqueDestination(dialog.FolderName, Path.GetFileName(source));
                        File.Copy(source, destination);
                        int done = Interlocked.Increment(ref copied);
                        Dispatcher.BeginInvoke(new Action(() => WorkProgressBar.Value = done));
                    }
                });
                SetStatus($"已导出 {copied} 个原始文件");
            }
            catch (Exception ex) { SetStatus($"导出失败：{ex.Message}"); }
            finally { SetWorking(false); }
        }

        private async void BtnTrashFavorites_Click(object sender, RoutedEventArgs e)
        {
            var favorites = ScopedPhotos().Where(photo => photo.IsFavorite).ToList();
            if (favorites.Count == 0) { SetStatus("“我喜欢”中没有照片"); return; }
            await ConfirmAndTrashAsync(favorites);
        }

        private async Task ConfirmAndTrashAsync(List<PhotoItem> photos)
        {
            if (_isWorking || photos.Count == 0) return;
            if (MessageBox.Show(
                    $"将 {photos.Count} 个媒体项目移入 Windows 回收站？\n配套的 MOV/MP4 也会一起移动。",
                    "移入回收站",
                    MessageBoxButton.OKCancel,
                    MessageBoxImage.Warning) != MessageBoxResult.OK) return;

            string? fallbackId = null;
            if (ViewerMode.Visibility == Visibility.Visible && _viewerIndex >= 0 && _viewerIndex < _visiblePhotos.Count)
            {
                fallbackId = _visiblePhotos.Skip(_viewerIndex + 1).FirstOrDefault(item => !photos.Contains(item))?.StableId
                    ?? _visiblePhotos.Take(_viewerIndex).LastOrDefault(item => !photos.Contains(item))?.StableId;
                StopMediaPlayback();
            }

            var paths = photos.SelectMany(photo => photo.OriginalResourcePaths)
                .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            SetWorking(true, 0, Math.Max(1, paths.Count));
            try
            {
                TrashResult result = await TrashService.MoveToTrashAsync(paths,
                    (done, _) => Dispatcher.BeginInvoke(new Action(() => WorkProgressBar.Value = done)));
                var removed = photos.Where(photo => !File.Exists(photo.FilePath)).ToList();
                foreach (PhotoItem photo in removed)
                {
                    _favoriteStore.Remove(photo.Directory, photo.FileName);
                    _tagStore.RemoveAll(photo.Directory, photo.FileName);
                    _holdFrameStore.Remove(photo.FilePath);
                    _cardMap.Remove(photo.StableId);
                    _thumbnailMap.Remove(photo.StableId);
                    _photos.Remove(photo);
                }
                BuildDirectoryTree();
                RenderGallery();
                if (ViewerMode.Visibility == Visibility.Visible)
                {
                    int target = fallbackId == null ? -1 : _visiblePhotos.FindIndex(item =>
                        string.Equals(item.StableId, fallbackId, StringComparison.OrdinalIgnoreCase));
                    if (target >= 0) LoadViewerPhoto(target); else ExitViewerMode();
                }
                SetStatus(result.FailedCount == 0
                    ? $"已将 {removed.Count} 个媒体项目移入回收站"
                    : $"已移入 {removed.Count} 个，{result.FailedCount} 个文件失败");
            }
            catch (Exception ex) { SetStatus($"移入回收站失败：{ex.Message}"); }
            finally { SetWorking(false); }
        }

        private async void BtnSyncAndroid_Click(object sender, RoutedEventArgs e)
        {
            if (_isWorking) return;
            var paths = ScopedPhotos().Where(photo => photo.IsFavorite)
                .SelectMany(photo => photo.OriginalResourcePaths)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Where(File.Exists)
                .ToList();
            if (paths.Count == 0) { SetStatus("“我喜欢”中没有可同步的文件"); return; }
            string? adb = FindExecutable("adb.exe") ?? FindExecutable("adb");
            if (adb == null) { SetStatus("未找到 adb，请先安装 Android platform-tools"); return; }
            if (MessageBox.Show(
                    $"将 {paths.Count} 个原始文件同步到安卓手机的 DCIM/MotionAlbum，并在完成后尝试打开微信？",
                    "同步到安卓手机",
                    MessageBoxButton.OKCancel,
                    MessageBoxImage.Question) != MessageBoxResult.OK) return;
            SetStatus($"正在同步 0/{paths.Count}…");
            SetWorking(true, 0, Math.Max(1, paths.Count));
            const string remoteDirectory = "/sdcard/DCIM/MotionAlbum";
            try
            {
                string devicesOutput = await RunProcessAsync(adb, "devices");
                int deviceCount = devicesOutput.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                    .Skip(1)
                    .Count(line => line.EndsWith("\tdevice", StringComparison.Ordinal));
                if (deviceCount == 0) { SetStatus("没有检测到已授权的安卓手机"); return; }
                if (deviceCount > 1) { SetStatus("检测到多台安卓设备，请暂时只连接一台"); return; }

                await RunProcessAsync(adb, "shell", "mkdir", "-p", remoteDirectory);
                for (int index = 0; index < paths.Count; index++)
                {
                    string fileName = SanitizeAndroidFileName(Path.GetFileName(paths[index]));
                    string remotePath = $"{remoteDirectory}/{fileName}";
                    await RunProcessAsync(adb, "push", paths[index], remotePath);
                    await RunProcessAsync(
                        adb, "shell", "am", "broadcast",
                        "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                        "-d", $"file://{remotePath}");
                    WorkProgressBar.Value = index + 1;
                    SetStatus($"正在同步 {index + 1}/{paths.Count}…");
                }
                try
                {
                    await RunProcessAsync(adb, "shell", "monkey", "-p", "com.tencent.mm", "-c", "android.intent.category.LAUNCHER", "1");
                }
                catch { }
                SetStatus($"已同步 {paths.Count} 个原始文件到安卓手机：{remoteDirectory}");
            }
            catch (Exception ex)
            {
                SetStatus($"同步失败：{ex.Message}");
            }
            finally { SetWorking(false); }
        }

        private static string SanitizeAndroidFileName(string fileName) => new(
            fileName.Select(character => char.IsLetterOrDigit(character) || character is '.' or '_' or '-'
                ? character : '_').ToArray());

        private static string UniqueDestination(string directory, string fileName)
        {
            string destination = Path.Combine(directory, fileName);
            if (!File.Exists(destination)) return destination;
            string stem = Path.GetFileNameWithoutExtension(fileName);
            string extension = Path.GetExtension(fileName);
            for (int index = 2; ; index++)
            {
                destination = Path.Combine(directory, $"{stem} ({index}){extension}");
                if (!File.Exists(destination)) return destination;
            }
        }

        private static string? FindExecutable(string name)
        {
            foreach (string directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
                         .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            {
                string candidate = Path.Combine(directory.Trim().Trim('"'), name);
                if (File.Exists(candidate)) return candidate;
            }
            return null;
        }

        private static async Task<string> RunProcessAsync(string executable, params string[] arguments)
        {
            var startInfo = new ProcessStartInfo(executable)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            foreach (string argument in arguments) startInfo.ArgumentList.Add(argument);
            using var process = Process.Start(startInfo);
            if (process == null) throw new InvalidOperationException($"无法启动 {Path.GetFileName(executable)}");
            Task<string> outputTask = process.StandardOutput.ReadToEndAsync();
            Task<string> errorTask = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            string output = await outputTask;
            string error = await errorTask;
            if (process.ExitCode != 0)
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? output.Trim() : error.Trim());
            return output;
        }

        // MARK: - Keyboard, theme and status

        private void MainWindow_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            bool control = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
            if (control && e.Key == Key.B)
            {
                BtnToggleSidebar_Click(sender, e);
                e.Handled = true;
                return;
            }
            if (control && e.Key == Key.O)
            {
                BtnOpenFolder_Click(sender, e);
                e.Handled = true;
                return;
            }
            if (control && e.Key == Key.R)
            {
                BtnRefresh_Click(sender, e);
                e.Handled = true;
                return;
            }
            if (control && e.Key == Key.E)
            {
                BtnExport_Click(sender, e);
                e.Handled = true;
                return;
            }
            if (control && e.Key is Key.OemPlus or Key.Add)
            {
                if (ViewerMode.Visibility == Visibility.Visible) ViewerZoomIn_Click(sender, e);
                else StepGalleryZoom(1);
                e.Handled = true;
                return;
            }
            if (control && e.Key is Key.OemMinus or Key.Subtract)
            {
                if (ViewerMode.Visibility == Visibility.Visible) ViewerZoomOut_Click(sender, e);
                else StepGalleryZoom(-1);
                e.Handled = true;
                return;
            }
            if (control && (e.Key is Key.D0 or Key.NumPad0) && ViewerMode.Visibility == Visibility.Visible)
            {
                ResetViewerTransform();
                e.Handled = true;
                return;
            }
            if (Keyboard.FocusedElement is TextBox or ComboBox) return;

            if (ViewerMode.Visibility == Visibility.Visible)
            {
                switch (e.Key)
                {
                    case Key.Escape: ExitViewerMode(); break;
                    case Key.Left:
                    case Key.A: NavigateViewer(-1); break;
                    case Key.Right:
                    case Key.D: NavigateViewer(1); break;
                    case Key.Space: ViewerPlay_Click(sender, e); break;
                    default: return;
                }
                e.Handled = true;
                return;
            }

            if (_visiblePhotos.Count == 0) return;
            int current = _focusedPhotoId == null ? -1 : _visiblePhotos.FindIndex(photo =>
                string.Equals(photo.StableId, _focusedPhotoId, StringComparison.OrdinalIgnoreCase));
            if (e.Key == Key.Enter)
            {
                EnterViewerMode(Math.Max(0, current));
                e.Handled = true;
                return;
            }

            int columns = IsShowcaseMode ? 1 : Math.Max(1, (int)(Math.Max(1, GalleryScrollViewer.ViewportWidth - 36) / (_galleryCardSize + 8)));
            int target = current < 0 ? 0 : current;
            switch (e.Key)
            {
                case Key.Left:
                case Key.A: target--; break;
                case Key.Right:
                case Key.D: target++; break;
                case Key.Up:
                case Key.W: target = VerticalNavigationTargetIndex(current, columns, movingDown: false); break;
                case Key.Down:
                case Key.S: target = VerticalNavigationTargetIndex(current, columns, movingDown: true); break;
                default: return;
            }
            target = Math.Clamp(target, 0, _visiblePhotos.Count - 1);
            SetFocusedPhoto(_visiblePhotos[target]);
            ScrollToPhoto(_focusedPhotoId);
            e.Handled = true;
        }

        private int VerticalNavigationTargetIndex(int currentIndex, int columnCount, bool movingDown)
        {
            if (currentIndex < 0) return 0;
            if (!_groupByTime)
                return Math.Clamp(currentIndex + (movingDown ? columnCount : -columnCount), 0, _visiblePhotos.Count - 1);

            string format = _galleryCardSize < 150 ? "yyyy年M月" : "yyyy年M月d日";
            var sections = _visiblePhotos.GroupBy(photo => photo.TimelineDate.ToString(format))
                .Select(group => group.ToList()).ToList();
            PhotoItem current = _visiblePhotos[currentIndex];
            int sectionIndex = sections.FindIndex(section => section.Contains(current));
            if (sectionIndex < 0) return currentIndex;
            int itemIndex = sections[sectionIndex].IndexOf(current);
            int column = itemIndex % columnCount;
            if (movingDown)
            {
                if (itemIndex + columnCount < sections[sectionIndex].Count)
                    return _visiblePhotos.IndexOf(sections[sectionIndex][itemIndex + columnCount]);
                if (sectionIndex + 1 >= sections.Count) return currentIndex;
                PhotoItem target = sections[sectionIndex + 1][Math.Min(column, sections[sectionIndex + 1].Count - 1)];
                return _visiblePhotos.IndexOf(target);
            }
            if (itemIndex - columnCount >= 0)
                return _visiblePhotos.IndexOf(sections[sectionIndex][itemIndex - columnCount]);
            if (sectionIndex == 0) return currentIndex;
            List<PhotoItem> previous = sections[sectionIndex - 1];
            int lastRowStart = ((previous.Count - 1) / columnCount) * columnCount;
            PhotoItem previousTarget = previous[lastRowStart + Math.Min(column, previous.Count - 1 - lastRowStart)];
            return _visiblePhotos.IndexOf(previousTarget);
        }

        private void BtnThemeToggle_Click(object sender, RoutedEventArgs e)
        {
            ThemeManager.ToggleTheme();
            UpdateThemeButtonIcon();
            UpdateFilterVisuals();
            RenderGallery();
        }

        private void UpdateThemeButtonIcon()
        {
            var (icon, tooltip) = ThemeManager.GetThemeDisplay();
            ThemeIconText.Text = icon;
            BtnThemeToggle.ToolTip = $"当前：{tooltip}（点击切换）";
        }

        private void UpdateCounts()
        {
            List<PhotoItem> scopedPhotos = ScopedPhotos().ToList();
            int all = scopedPhotos.Count;
            int live = scopedPhotos.Count(photo => photo.IsLivePhoto);
            int video = scopedPhotos.Count(photo => photo.IsVideo);
            int favorite = scopedPhotos.Count(photo => photo.IsFavorite);
            int tagged = scopedPhotos.Count(photo => photo.Tags.Count > 0);
            AllCountText.Text = all.ToString("N0");
            LiveCountText.Text = live.ToString("N0");
            VideoCountText.Text = video.ToString("N0");
            FavoriteCountText.Text = favorite.ToString("N0");
            MetricAllText.Text = $"▣  全部  {all:N0}";
            MetricLiveText.Text = $"◎  实况  {live:N0}";
            MetricVideoText.Text = $"▶  视频  {video:N0}";
            MetricFavoriteText.Text = $"♥  喜欢  {favorite:N0}";
            MetricTagText.Text = $"◇  标签  {tagged:N0}";
            UpdateTagSidebar();
        }

        private void SetStatus(string value) => StatusText.Text = value;

        private void SetWorking(bool working, int value = 0, int maximum = 1)
        {
            _isWorking = working;
            WorkProgressBar.Minimum = 0;
            WorkProgressBar.Maximum = Math.Max(1, maximum);
            WorkProgressBar.Value = Math.Clamp(value, 0, Math.Max(1, maximum));
            WorkProgressBar.Visibility = working ? Visibility.Visible : Visibility.Collapsed;
            BtnExport.IsEnabled = !working;
            BtnSyncAndroid.IsEnabled = !working;
            BtnTrashFavorites.IsEnabled = !working;
            BtnViewerTrash.IsEnabled = !working;
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
            if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024):F1} MB";
            return $"{bytes / (1024.0 * 1024 * 1024):F2} GB";
        }
    }
}
