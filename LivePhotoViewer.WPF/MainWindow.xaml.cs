using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LibVLCSharp.Shared;
using LivePhotoViewer.WPF.Controls;
using LivePhotoViewer.WPF.Core;
using LivePhotoViewer.WPF.Models;
using Microsoft.Win32;

namespace LivePhotoViewer.WPF
{
    public partial class MainWindow : Window
    {
        private readonly FavoritesManager _favManager = new();
        private readonly TagsManager _tagsManager = new();
        private string _currentDir = string.Empty;
        private string _rootDir = string.Empty;
        private List<PhotoItem> _photos = new();
        private readonly Dictionary<string, ThumbnailCard> _cardMap = new();
        private readonly SemaphoreSlim _thumbSemaphore = new(4, 4);
        private CancellationTokenSource? _loadCts;

        // ========== 查看模式状态 ==========
        private int _viewerIndex = -1;
        private LibVLC? _libVlc;
        private LibVLCSharp.Shared.MediaPlayer? _mediaPlayer;
        private bool _isPlayingLive;
        private CancellationTokenSource? _viewerCts;

        // ========== 图片缩放状态 ==========
        private double _currentScale = 1.0;
        private bool _isDragging;
        private Point _dragStart;
        private Point _dragStartTranslate;
        private DateTime _lastClickTime;
        private Point _lastClickPos;

        // ========== 目录切换防抖 ==========
        private System.Windows.Threading.DispatcherTimer? _treeDebounceTimer;
        private string? _pendingTreePath;

        public MainWindow()
        {
            InitializeComponent();
            Loaded += MainWindow_Loaded;
            KeyDown += MainWindow_KeyDown;
            Closing += MainWindow_Closing;
        }

        private void MainWindow_Loaded(object sender, RoutedEventArgs e)
        {
            UpdateThemeButtonIcon();
            // 延迟初始化 LibVLC，避免启动时卡顿
            _ = Task.Run(() =>
            {
                try
                {
                    _libVlc = new LibVLC("--quiet", "--no-video-title-show", "--intf=dummy");
                }
                catch (Exception ex)
                {
                    Dispatcher.InvokeAsync(() => StatusText.Text = $"播放器初始化失败: {ex.Message}");
                }
            });
        }

        private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
        {
            _viewerCts?.Cancel();
            _loadCts?.Cancel();
            // 异步释放 VLC 资源，避免阻塞关闭
            _ = Task.Run(() =>
            {
                try { _mediaPlayer?.Stop(); } catch { }
                Thread.Sleep(100);
                try { _mediaPlayer?.Dispose(); } catch { }
                try { _libVlc?.Dispose(); } catch { }
            });
        }

        // ========== 文件夹加载 ==========
        private void BtnOpenFolder_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new OpenFolderDialog
            {
                Title = "选择照片文件夹",
                InitialDirectory = string.IsNullOrEmpty(_rootDir)
                    ? Environment.GetFolderPath(Environment.SpecialFolder.MyPictures)
                    : _rootDir
            };

            if (dialog.ShowDialog() == true)
            {
                _rootDir = dialog.FolderName;
                _ = BuildDirectoryTreeAsync(_rootDir);
                _ = LoadDirectoryAsync(dialog.FolderName);
            }
        }

        private void DirectoryTree_SelectedItemChanged(object sender, RoutedEventArgs e)
        {
            if (DirectoryTree.SelectedItem is DirectoryNode node)
            {
                _pendingTreePath = node.FullPath;
                if (_treeDebounceTimer == null)
                {
                    _treeDebounceTimer = new System.Windows.Threading.DispatcherTimer
                    {
                        Interval = TimeSpan.FromMilliseconds(150)
                    };
                    _treeDebounceTimer.Tick += (_, _) =>
                    {
                        _treeDebounceTimer?.Stop();
                        if (!string.IsNullOrEmpty(_pendingTreePath))
                        {
                            _ = LoadDirectoryAsync(_pendingTreePath);
                            _pendingTreePath = null;
                        }
                    };
                }
                _treeDebounceTimer.Stop();
                _treeDebounceTimer.Start();
            }
        }

        private async Task BuildDirectoryTreeAsync(string rootPath)
        {
            try
            {
                StatusText.Text = "正在扫描目录...";
                var rootNode = await Task.Run(() =>
                {
                    var node = new DirectoryNode
                    {
                        Name = Path.GetFileName(rootPath) ?? rootPath,
                        FullPath = rootPath,
                        PhotoCount = SafeCountJpg(rootPath)
                    };
                    AddSubDirectories(node, rootPath);
                    return node;
                });

                DirectoryTree.Items.Clear();
                DirectoryTree.Items.Add(rootNode);
                StatusText.Text = string.Empty;
            }
            catch (Exception ex)
            {
                StatusText.Text = $"目录树加载失败: {ex.Message}";
            }
        }

        private static int SafeCountJpg(string path)
        {
            try { return Directory.EnumerateFiles(path, "*.jpg").Count(); }
            catch { return 0; }
        }

        private void AddSubDirectories(DirectoryNode parent, string path)
        {
            try
            {
                foreach (var dir in Directory.EnumerateDirectories(path).OrderBy(d => d))
                {
                    int count = SafeCountJpg(dir);
                    var node = new DirectoryNode
                    {
                        Name = Path.GetFileName(dir),
                        FullPath = dir,
                        PhotoCount = count
                    };
                    AddSubDirectories(node, dir);

                    // 只显示包含 jpg 文件或有子目录的文件夹
                    if (count > 0 || node.Children.Count > 0)
                    {
                        parent.Children.Add(node);
                    }
                }
            }
            catch { }
        }

        private async Task LoadDirectoryAsync(string path)
        {
            _loadCts?.Cancel();
            _loadCts = new CancellationTokenSource();
            var token = _loadCts.Token;

            _currentDir = path;
            ThumbnailPanel.Children.Clear();
            _cardMap.Clear();
            StatusText.Text = "正在扫描文件夹...";
            RefreshTagFilterCombo();

            try
            {
                var jpgFiles = Directory.EnumerateFiles(path, "*.jpg")
                    .OrderBy(f => f)
                    .ToList();

                if (jpgFiles.Count == 0)
                {
                    StatusText.Text = $"{path}  |  0 张照片";
                    _photos.Clear();
                    return;
                }

                // 加载实况检测缓存
                var liveCache = ThumbnailCache.LoadLiveCache(path) ?? new Dictionary<string, bool>();
                var favSet = _favManager.GetFavorites(path);

                // 标签筛选
                string? selectedTag = TagFilterCombo.SelectedItem?.ToString();
                bool hasTagFilter = !string.IsNullOrEmpty(selectedTag) && selectedTag != "全部";

                _photos = jpgFiles.Select(fp => new PhotoItem
                {
                    FilePath = fp,
                    FileName = Path.GetFileName(fp),
                    Directory = path,
                    IsLivePhoto = liveCache.TryGetValue(fp, out var cached) ? cached : false,
                    IsFavorite = favSet.Contains(Path.GetFileName(fp)),
                    Tags = _tagsManager.GetTags(path, Path.GetFileName(fp))
                }).ToList();

                // 逐步显示占位卡片
                var cards = new List<ThumbnailCard>();
                int cardCount = 0;
                foreach (var photo in _photos)
                {
                    if (token.IsCancellationRequested) return;

                    // 收藏筛选
                    bool show = BtnFavFilter.IsChecked != true || photo.IsFavorite;
                    if (!show) continue;

                    // 标签筛选
                    if (hasTagFilter && !photo.Tags.Contains(selectedTag!))
                        continue;

                    var card = new ThumbnailCard(photo.FilePath, photo.IsFavorite, isLoading: true);
                    card.PhotoClicked += OnThumbnailClick;
                    card.FavoriteToggled += OnFavoriteToggle;
                    ThumbnailPanel.Children.Add(card);
                    _cardMap[photo.FilePath] = card;
                    cards.Add(card);

                    cardCount++;
                    if (cardCount % 20 == 0)
                        await Task.Delay(1);
                }

                StatusText.Text = $"{Path.GetFileName(path)}  |  正在生成缩略图...";

                // 后台并行生成缩略图和检测实况
                var tasks = cards.Select(card => Task.Run(async () =>
                {
                    if (token.IsCancellationRequested) return;

                    await _thumbSemaphore.WaitAsync(token);
                    try
                    {
                        var photo = _photos.First(p => p.FilePath == card.FilePath);

                        // 先尝试读取缓存
                        string? cachedThumb = ThumbnailCache.GetThumbnailPath(card.FilePath);
                        BitmapImage? bitmap = null;

                        if (cachedThumb != null)
                        {
                            bitmap = LoadBitmapAsync(cachedThumb);
                        }
                        else
                        {
                            var bytes = ThumbnailCache.GenerateThumbnailBytes(card.FilePath, 200);
                            if (bytes != null)
                            {
                                ThumbnailCache.SaveThumbnail(card.FilePath, bytes);
                                bitmap = LoadBitmapFromBytes(bytes);
                            }
                        }

                        // 实况检测（如果没有缓存）
                        if (!liveCache.ContainsKey(card.FilePath))
                        {
                            photo.IsLivePhoto = LivePhotoExtractor.IsLivePhoto(card.FilePath);
                            liveCache[card.FilePath] = photo.IsLivePhoto;
                        }

                        // 更新 UI
                        await Dispatcher.InvokeAsync(() =>
                        {
                            if (token.IsCancellationRequested) return;
                            card.SetLoaded(bitmap, photo.IsLivePhoto);
                            card.SetTags(photo.Tags);
                        });
                    }
                    catch { }
                    finally
                    {
                        _thumbSemaphore.Release();
                    }
                }, token)).ToArray();

                await Task.WhenAll(tasks);

                // 保存实况缓存
                ThumbnailCache.SaveLiveCache(path, liveCache);
                UpdateStatus();
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                StatusText.Text = $"加载失败: {ex.Message}";
            }
        }

        private static BitmapImage? LoadBitmapAsync(string path)
        {
            try
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.UriSource = new Uri(path);
                bmp.EndInit();
                bmp.Freeze();
                return bmp;
            }
            catch { return null; }
        }

        private static BitmapImage? LoadBitmapFromBytes(byte[] bytes)
        {
            try
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.StreamSource = new MemoryStream(bytes);
                bmp.EndInit();
                bmp.Freeze();
                return bmp;
            }
            catch { return null; }
        }

        // ========== 缩略图交互 ==========
        private void OnThumbnailClick(object? sender, string filePath)
        {
            int idx = _photos.FindIndex(p => p.FilePath == filePath);
            if (idx >= 0) EnterViewerMode(idx);
        }

        private void OnFavoriteToggle(object? sender, string filePath)
        {
            string name = Path.GetFileName(filePath);
            bool newState = _favManager.Toggle(_currentDir, name);

            var photo = _photos.FirstOrDefault(p => p.FilePath == filePath);
            if (photo != null) photo.IsFavorite = newState;

            if (BtnFavFilter.IsChecked == true && !newState)
            {
                _ = LoadDirectoryAsync(_currentDir);
            }
            UpdateStatus();
        }

        // ========== 标签筛选 ==========
        private void RefreshTagFilterCombo()
        {
            string? previous = TagFilterCombo.SelectedItem?.ToString();
            var tags = _tagsManager.GetAllTags(_currentDir).ToList();
            tags.Sort();
            tags.Insert(0, "全部");

            TagFilterCombo.ItemsSource = tags;

            if (previous != null && tags.Contains(previous))
                TagFilterCombo.SelectedItem = previous;
            else
                TagFilterCombo.SelectedIndex = 0;
        }

        private void TagFilterCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (!string.IsNullOrEmpty(_currentDir))
                _ = LoadDirectoryAsync(_currentDir);
        }

        private void BtnClearTagFilter_Click(object sender, RoutedEventArgs e)
        {
            TagFilterCombo.SelectedIndex = 0;
        }

        // ========== 查看模式 ==========
        private void EnterViewerMode(int index)
        {
            if (_photos.Count == 0 || index < 0 || index >= _photos.Count) return;

            _viewerIndex = index;
            GridMode.Visibility = Visibility.Collapsed;
            ViewerMode.Visibility = Visibility.Visible;
            ViewerMode.Focusable = true;
            ViewerMode.Focus();

            LoadViewerPhoto(_viewerIndex);
        }

        private void ExitViewerMode()
        {
            StopLivePlayback();
            ResetImageTransform();
            ViewerMode.Visibility = Visibility.Collapsed;
            GridMode.Visibility = Visibility.Visible;
            _viewerIndex = -1;
        }

        private void LoadViewerPhoto(int index)
        {
            _viewerCts?.Cancel();
            _viewerCts = new CancellationTokenSource();
            StopLivePlayback();

            var photo = _photos[index];

            // 加载静态图片
            var bmp = LoadBitmapAsync(photo.FilePath);
            ViewerImage.Source = bmp;
            ViewerImage.Visibility = Visibility.Visible;
            ViewerVideoView.Visibility = Visibility.Collapsed;

            // 更新信息栏
            var fi = new FileInfo(photo.FilePath);
            string type = photo.IsLivePhoto ? "实况照片" : "普通照片";
            string res = bmp != null ? $"{bmp.PixelWidth} x {bmp.PixelHeight}" : "未知";
            ViewerInfoText.Text = $"{photo.FileName}  |  {res}  |  {FormatBytes(fi.Length)}  |  {type}";

            // 更新收藏按钮状态
            UpdateViewerFavButton();

            // 显示/隐藏播放按钮
            BtnViewerPlay.Visibility = photo.IsLivePhoto ? Visibility.Visible : Visibility.Collapsed;

            // 更新标签显示
            UpdateViewerTags(photo);

            // 重置缩放
            ResetImageTransform();

            // 预加载实况视频数据（后台提取但不播放）
            if (photo.IsLivePhoto && _libVlc != null)
            {
                _ = Task.Run(() =>
                {
                    try
                    {
                        string? tempMp4 = LivePhotoExtractor.ExtractMp4ToTemp(photo.FilePath);
                        if (tempMp4 != null)
                        {
                            photo.TempMp4Path = tempMp4;
                        }
                    }
                    catch { }
                });
            }
        }

        private void UpdateViewerTags(PhotoItem photo)
        {
            ViewerTagsPanel.Children.Clear();
            foreach (var tag in photo.Tags)
            {
                var border = new Border
                {
                    Style = (Style)FindResource("TagChipStyle"),
                    Child = new TextBlock
                    {
                        Text = tag,
                        FontSize = 11,
                        Foreground = Brushes.White,
                        VerticalAlignment = VerticalAlignment.Center
                    }
                };

                // 删除按钮
                var removeBtn = new Button
                {
                    Content = " x",
                    FontSize = 10,
                    Foreground = Brushes.White,
                    Background = Brushes.Transparent,
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(2, 0, 0, 0),
                    Cursor = System.Windows.Input.Cursors.Hand,
                    Tag = tag
                };
                removeBtn.Click += async (s, e) =>
                {
                    if (s is Button btn && btn.Tag is string t)
                    {
                        await _tagsManager.RemoveTagAsync(_currentDir, photo.FileName, t);
                        photo.Tags.Remove(t);
                        UpdateViewerTags(photo);
                        RefreshTagFilterCombo();
                        SyncThumbnailCardTags(photo.FilePath, photo.Tags);

                        // 如果当前有标签筛选，需要重载以更新筛选结果
                        string? selectedTag = TagFilterCombo.SelectedItem?.ToString();
                        if (!string.IsNullOrEmpty(selectedTag) && selectedTag != "全部")
                            _ = LoadDirectoryAsync(_currentDir);
                    }
                };

                var panel = new StackPanel { Orientation = Orientation.Horizontal };
                panel.Children.Add(border.Child);
                panel.Children.Add(removeBtn);
                border.Child = panel;

                ViewerTagsPanel.Children.Add(border);
            }
        }

        private void BtnAddTag_Click(object sender, RoutedEventArgs e)
        {
            AddTagFromInput();
        }

        private void TagInputBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
            {
                AddTagFromInput();
                e.Handled = true;
            }
        }

        private async void AddTagFromInput()
        {
            if (_viewerIndex < 0 || _viewerIndex >= _photos.Count) return;
            var photo = _photos[_viewerIndex];
            string tag = TagInputBox.Text.Trim();
            if (string.IsNullOrEmpty(tag)) return;

            await _tagsManager.AddTagAsync(_currentDir, photo.FileName, tag);
            if (!photo.Tags.Contains(tag))
                photo.Tags.Add(tag);

            TagInputBox.Clear();
            UpdateViewerTags(photo);
            RefreshTagFilterCombo();
            SyncThumbnailCardTags(photo.FilePath, photo.Tags);

            // 如果当前有标签筛选，需要重载以更新筛选结果
            string? selectedTag = TagFilterCombo.SelectedItem?.ToString();
            if (!string.IsNullOrEmpty(selectedTag) && selectedTag != "全部")
                _ = LoadDirectoryAsync(_currentDir);
        }

        /// <summary>
        /// 只更新对应缩略图卡片的标签显示，不重新加载整个目录
        /// </summary>
        private void SyncThumbnailCardTags(string filePath, List<string> tags)
        {
            if (_cardMap.TryGetValue(filePath, out var card))
            {
                card.SetTags(tags);
            }
        }

        private void StopLivePlayback()
        {
            _isPlayingLive = false;
            ViewerPlayIconText.Text = "▶";
            ViewerPlayLabelText.Text = "播放";
            BtnViewerPlay.ToolTip = "播放实况";

            if (_mediaPlayer != null)
            {
                try
                {
                    _mediaPlayer.Stop();
                }
                catch { }
            }

            // 确保 VideoView 隐藏，图片显示
            ViewerVideoView.Visibility = Visibility.Collapsed;
            ViewerImage.Visibility = Visibility.Visible;
        }

        private void PlayLivePhoto()
        {
            if (_viewerIndex < 0 || _viewerIndex >= _photos.Count) return;
            var photo = _photos[_viewerIndex];
            if (!photo.IsLivePhoto || _libVlc == null) return;

            // 如果已经提取过临时文件，直接播放；否则先提取
            string? mp4Path = photo.TempMp4Path;
            if (string.IsNullOrEmpty(mp4Path) || !File.Exists(mp4Path))
            {
                mp4Path = LivePhotoExtractor.ExtractMp4ToTemp(photo.FilePath);
                if (mp4Path == null) return;
                photo.TempMp4Path = mp4Path;
            }

            // 确保 MediaPlayer 已创建
            if (_mediaPlayer == null)
            {
                _mediaPlayer = new LibVLCSharp.Shared.MediaPlayer(_libVlc);
                ViewerVideoView.MediaPlayer = _mediaPlayer;

                // 播放结束事件 - 严禁在回调中直接 Stop/Dispose，只更新 UI
                _mediaPlayer.EndReached += (s, e) =>
                {
                    Dispatcher.BeginInvoke(() =>
                    {
                        _isPlayingLive = false;
                        ViewerPlayIconText.Text = "▶";
                        ViewerPlayLabelText.Text = "播放";
                        BtnViewerPlay.ToolTip = "播放实况";
                        ViewerVideoView.Visibility = Visibility.Collapsed;
                        ViewerImage.Visibility = Visibility.Visible;
                    });
                };
            }

            // 切换显示层
            ViewerImage.Visibility = Visibility.Collapsed;
            ViewerVideoView.Visibility = Visibility.Visible;

            using var media = new Media(_libVlc, new Uri(mp4Path));
            _mediaPlayer.Play(media);
            _isPlayingLive = true;
            ViewerPlayIconText.Text = "⏸";
            ViewerPlayLabelText.Text = "暂停";
            BtnViewerPlay.ToolTip = "暂停";
        }

        private void ToggleLivePlayback()
        {
            if (_isPlayingLive)
            {
                StopLivePlayback();
            }
            else
            {
                PlayLivePhoto();
            }
        }

        // ========== 查看器按钮事件 ==========
        private void ViewerPrev_Click(object sender, RoutedEventArgs e)
        {
            if (_viewerIndex > 0)
            {
                _viewerIndex--;
                LoadViewerPhoto(_viewerIndex);
            }
        }

        private void ViewerNext_Click(object sender, RoutedEventArgs e)
        {
            if (_viewerIndex >= 0 && _viewerIndex < _photos.Count - 1)
            {
                _viewerIndex++;
                LoadViewerPhoto(_viewerIndex);
            }
        }

        private void ViewerPlay_Click(object sender, RoutedEventArgs e)
        {
            ToggleLivePlayback();
        }

        private void ViewerFav_Click(object sender, RoutedEventArgs e)
        {
            if (_viewerIndex < 0 || _viewerIndex >= _photos.Count) return;
            var photo = _photos[_viewerIndex];
            string name = Path.GetFileName(photo.FilePath);
            bool newState = _favManager.Toggle(_currentDir, name);
            photo.IsFavorite = newState;
            UpdateViewerFavButton();
            UpdateStatus();

            // 同步更新缩略图卡片上的收藏状态
            if (_cardMap.TryGetValue(photo.FilePath, out var card))
            {
                card.IsFavorite = newState;
            }
        }

        private void UpdateViewerFavButton()
        {
            if (_viewerIndex < 0 || _viewerIndex >= _photos.Count) return;
            bool isFav = _photos[_viewerIndex].IsFavorite;
            ViewerFavIconText.Text = isFav ? "★" : "☆";
            ViewerFavIconText.Foreground = isFav
                ? new SolidColorBrush(Color.FromArgb(255, 255, 149, 0))
                : (Brush)Application.Current.FindResource("TextBrush")!;
        }

        private void ViewerClose_Click(object sender, RoutedEventArgs e)
        {
            ExitViewerMode();
        }

        // ========== 图片缩放与拖拽 ==========
        private void ResetImageTransform()
        {
            _currentScale = 1.0;
            _isDragging = false;
            ViewerScaleTransform.ScaleX = 1;
            ViewerScaleTransform.ScaleY = 1;
            ViewerTranslateTransform.X = 0;
            ViewerTranslateTransform.Y = 0;
            LeftNavZone.Visibility = Visibility.Visible;
            RightNavZone.Visibility = Visibility.Visible;
        }

        private void ViewerImageContainer_MouseWheel(object sender, MouseWheelEventArgs e)
        {
            if (ViewerImage.Source == null) return;

            double delta = e.Delta > 0 ? 1.15 : 0.85;
            double newScale = _currentScale * delta;
            if (newScale > 5) newScale = 5;
            if (newScale < 0.1) newScale = 0.1;

            // 以鼠标位置为中心缩放
            Point mouseOnImage = e.GetPosition(ViewerImage);
            double mx = mouseOnImage.X - ViewerImage.ActualWidth / 2;
            double my = mouseOnImage.Y - ViewerImage.ActualHeight / 2;

            ViewerTranslateTransform.X += mx * (_currentScale - newScale);
            ViewerTranslateTransform.Y += my * (_currentScale - newScale);
            ViewerScaleTransform.ScaleX = newScale;
            ViewerScaleTransform.ScaleY = newScale;
            _currentScale = newScale;

            // 缩放时隐藏左右翻页区，避免误触
            bool isZoomed = _currentScale > 1.01;
            LeftNavZone.Visibility = isZoomed ? Visibility.Collapsed : Visibility.Visible;
            RightNavZone.Visibility = isZoomed ? Visibility.Collapsed : Visibility.Visible;

            e.Handled = true;
        }

        private void ViewerImageContainer_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            // 双击检测（300ms 内同位置再次点击）
            var now = DateTime.Now;
            var pos = e.GetPosition(ViewerImageContainer);
            if ((now - _lastClickTime).TotalMilliseconds < 300 &&
                Math.Abs(pos.X - _lastClickPos.X) < 5 &&
                Math.Abs(pos.Y - _lastClickPos.Y) < 5)
            {
                ResetImageTransform();
                e.Handled = true;
                return;
            }
            _lastClickTime = now;
            _lastClickPos = pos;

            if (_currentScale > 1.01)
            {
                _isDragging = true;
                _dragStart = pos;
                _dragStartTranslate = new Point(ViewerTranslateTransform.X, ViewerTranslateTransform.Y);
                ViewerImageContainer.CaptureMouse();
                e.Handled = true;
            }
        }

        private void ViewerImageContainer_MouseMove(object sender, MouseEventArgs e)
        {
            if (_isDragging)
            {
                Point current = e.GetPosition(ViewerImageContainer);
                ViewerTranslateTransform.X = _dragStartTranslate.X + (current.X - _dragStart.X);
                ViewerTranslateTransform.Y = _dragStartTranslate.Y + (current.Y - _dragStart.Y);
                e.Handled = true;
            }
        }

        private void ViewerImageContainer_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (_isDragging)
            {
                _isDragging = false;
                ViewerImageContainer.ReleaseMouseCapture();
                e.Handled = true;
            }
        }

        // ========== 键盘事件 ==========
        private void MainWindow_KeyDown(object sender, KeyEventArgs e)
        {
            if (ViewerMode.Visibility != Visibility.Visible) return;

            switch (e.Key)
            {
                case Key.Escape:
                    ExitViewerMode();
                    e.Handled = true;
                    break;
                case Key.Left:
                    ViewerPrev_Click(sender, e);
                    e.Handled = true;
                    break;
                case Key.Right:
                    ViewerNext_Click(sender, e);
                    e.Handled = true;
                    break;
                case Key.Space:
                    ToggleLivePlayback();
                    e.Handled = true;
                    break;
            }
        }

        // ========== 收藏筛选 ==========
        private void BtnFavFilter_Checked(object sender, RoutedEventArgs e)
        {
            if (!string.IsNullOrEmpty(_currentDir))
                _ = LoadDirectoryAsync(_currentDir);
        }

        private void BtnFavFilter_Unchecked(object sender, RoutedEventArgs e)
        {
            if (!string.IsNullOrEmpty(_currentDir))
                _ = LoadDirectoryAsync(_currentDir);
        }

        private void UpdateStatus()
        {
            int total = _photos.Count;
            int favCount = _photos.Count(p => p.IsFavorite);
            StatusText.Text = $"{Path.GetFileName(_currentDir)}  |  共 {total} 张  |  已收藏 {favCount} 张";
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
            if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024):F1} MB";
            return $"{bytes / (1024.0 * 1024 * 1024):F2} GB";
        }

        // ========== 主题切换 ==========
        private void BtnThemeToggle_Click(object sender, RoutedEventArgs e)
        {
            ThemeManager.ToggleTheme();
            UpdateThemeButtonIcon();
        }

        private void UpdateThemeButtonIcon()
        {
            var (icon, tooltip) = ThemeManager.GetThemeDisplay();
            ThemeIconText.Text = icon;
            ThemeLabelText.Text = tooltip;
            BtnThemeToggle.ToolTip = $"当前: {tooltip} (点击切换)";
        }
    }
}
