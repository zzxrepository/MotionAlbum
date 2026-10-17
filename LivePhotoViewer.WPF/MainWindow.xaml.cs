using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
        private enum RotationSaveChoice { Cancel, SaveAdjustment, SaveAs, Overwrite }
        private enum ResourceSelectionSurface { Gallery, DirectoryTree }

        private readonly FavoritesManager _favoriteStore = new();
        private readonly TagsManager _tagStore = new();
        private readonly RecentFoldersManager _recentFolders = new();
        private readonly HoldFrameManager _holdFrameStore = new();
        private readonly RotationManager _rotationStore = new();
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
        private List<string> _directories = new();
        private CancellationTokenSource? _loadCts;
        private CancellationTokenSource? _showcasePreviewCts;
        private string _currentDirectory = string.Empty;
        private string _browsingDirectory = string.Empty;
        private LibraryFilter _filter = LibraryFilter.All;
        private string? _selectedTag;
        private string _tagSidebarSignature = string.Empty;
        private string? _focusedPhotoId;
        private string? _previousFocusedPhotoId;
        private readonly HashSet<string> _selectedPhotoIds = new(StringComparer.OrdinalIgnoreCase);
        private string? _selectionAnchorId;
        private readonly HashSet<string> _selectedDirectoryPaths = new(StringComparer.OrdinalIgnoreCase);
        private string? _directorySelectionAnchorPath;
        private ResourceSelectionSurface _activeResourceSelectionSurface = ResourceSelectionSurface.Gallery;
        private List<List<string>> _copiedResourceBundles = new();
        private List<string> _copiedClipboardPaths = new();
        private double _galleryCardSize = 126;
        private bool _isSidebarVisible = true;
        private const double DefaultSidebarWidth = 238;
        private const double MinimumSidebarWidth = 210;
        private const double MaximumSidebarWidth = 600;
        private const double MinimumLibraryWidth = 620;
        private const double SidebarDividerWidth = 12;
        private double _sidebarWidth = DefaultSidebarWidth;
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
        private int _viewerRotationQuarterTurns;

        public MainWindow()
        {
            InitializeComponent();
            Loaded += MainWindow_Loaded;
            Closing += MainWindow_Closing;
            SizeChanged += (_, _) =>
            {
                UpdateSidebarWidthForWindow();
                if (IsShowcaseMode && _visiblePhotos.Count > 0) RenderGallery();
            };
        }

        private bool IsShowcaseMode => _galleryCardSize >= 520;

        private void MainWindow_Loaded(object sender, RoutedEventArgs e)
        {
            _isSidebarVisible = _settings.SidebarVisible;
            _sidebarWidth = _settings.SidebarWidth;
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
            if (_isSidebarVisible)
                _settings.SidebarWidth = _sidebarWidth;
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
            if (Directory.Exists(_currentDirectory))
                _ = OpenDirectoryAsync(_currentDirectory, remember: false, browsingDirectory: _browsingDirectory);
        }

        private void IncludeSubfoldersCheckBox_Click(object sender, RoutedEventArgs e)
        {
            if (!Directory.Exists(_currentDirectory)) return;
            _selectedPhotoIds.Clear();
            _selectionAnchorId = null;
            _focusedPhotoId = null;
            _previousFocusedPhotoId = null;
            _selectedTag = null;
            LibraryPathText.Text = _browsingDirectory;
            RenderGallery();
            SetStatus(CurrentScopeSummary());
        }

        private void DirectoryTreeView_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
        {
            if (_suppressDirectorySelection || e.NewValue is not DirectoryNode node) return;
            SelectDirectoryNode(node, ModifierKeys.None);
            ActivateDirectoryNode(node);
        }

        private void DirectoryTreeView_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (FindVisualParent<ToggleButton>(e.OriginalSource as DependencyObject) != null) return;
            if (FindVisualParent<TreeViewItem>(e.OriginalSource as DependencyObject) is not { } treeItem ||
                treeItem.DataContext is not DirectoryNode node) return;

            ModifierKeys modifiers = Keyboard.Modifiers & (ModifierKeys.Shift | ModifierKeys.Control);
            SelectDirectoryNode(node, modifiers);
            _suppressDirectorySelection = true;
            treeItem.IsSelected = _selectedDirectoryPaths.Contains(node.FullPath);
            treeItem.Focus();
            _suppressDirectorySelection = false;
            ActivateDirectoryNode(node);
            e.Handled = true;
        }

        private void ActivateDirectoryNode(DirectoryNode node)
        {
            if (node.IsMediaFile)
            {
                FocusDirectoryTreeMedia(node);
                return;
            }
            if (!Directory.Exists(node.FullPath)) return;
            node.IsExpanded = node.Children.Count > 0;
            _selectedPhotoIds.Clear();
            _selectionAnchorId = null;
            _browsingDirectory = Path.GetFullPath(node.FullPath);
            _focusedPhotoId = null;
            _previousFocusedPhotoId = null;
            _selectedTag = null;
            LibraryPathText.Text = _browsingDirectory;
            RenderGallery();
            SetStatus(CurrentScopeSummary());
        }

        private void SelectDirectoryNode(DirectoryNode node, ModifierKeys modifiers)
        {
            _activeResourceSelectionSurface = ResourceSelectionSurface.DirectoryTree;
            _selectedPhotoIds.Clear();
            _selectionAnchorId = null;
            RefreshPhotoSelectionVisuals();

            bool extendRange = modifiers.HasFlag(ModifierKeys.Shift);
            bool toggle = modifiers.HasFlag(ModifierKeys.Control);
            List<DirectoryNode> visibleNodes = VisibleDirectoryNodes();
            if (extendRange && _directorySelectionAnchorPath != null)
            {
                int anchor = visibleNodes.FindIndex(item => string.Equals(
                    item.FullPath, _directorySelectionAnchorPath, StringComparison.OrdinalIgnoreCase));
                int target = visibleNodes.FindIndex(item => string.Equals(
                    item.FullPath, node.FullPath, StringComparison.OrdinalIgnoreCase));
                if (anchor >= 0 && target >= 0)
                {
                    if (!toggle) _selectedDirectoryPaths.Clear();
                    int start = Math.Min(anchor, target);
                    int end = Math.Max(anchor, target);
                    for (int index = start; index <= end; index++)
                        _selectedDirectoryPaths.Add(visibleNodes[index].FullPath);
                }
                else
                {
                    SelectSingleDirectoryNode(node);
                }
            }
            else if (toggle)
            {
                if (!_selectedDirectoryPaths.Add(node.FullPath))
                    _selectedDirectoryPaths.Remove(node.FullPath);
                _directorySelectionAnchorPath = node.FullPath;
            }
            else
            {
                SelectSingleDirectoryNode(node);
            }

            RefreshDirectorySelectionVisuals();
            SetStatus(_selectedDirectoryPaths.Count == 1
                ? "已选择 1 个资源"
                : $"已选择 {_selectedDirectoryPaths.Count:N0} 个资源");
        }

        private void SelectSingleDirectoryNode(DirectoryNode node)
        {
            _selectedDirectoryPaths.Clear();
            _selectedDirectoryPaths.Add(node.FullPath);
            _directorySelectionAnchorPath = node.FullPath;
        }

        private void ClearDirectorySelection()
        {
            if (_selectedDirectoryPaths.Count == 0 && _directorySelectionAnchorPath == null) return;
            _selectedDirectoryPaths.Clear();
            _directorySelectionAnchorPath = null;
            RefreshDirectorySelectionVisuals();
        }

        private void SelectAllVisibleDirectoryNodes()
        {
            List<DirectoryNode> visibleNodes = VisibleDirectoryNodes();
            if (visibleNodes.Count == 0) return;
            _activeResourceSelectionSurface = ResourceSelectionSurface.DirectoryTree;
            _selectedPhotoIds.Clear();
            _selectionAnchorId = null;
            RefreshPhotoSelectionVisuals();
            _selectedDirectoryPaths.Clear();
            foreach (DirectoryNode node in visibleNodes) _selectedDirectoryPaths.Add(node.FullPath);
            _directorySelectionAnchorPath = visibleNodes[0].FullPath;
            RefreshDirectorySelectionVisuals();
            SetStatus($"已选择资源管理器中可见的 {_selectedDirectoryPaths.Count:N0} 个项目");
        }

        private List<DirectoryNode> VisibleDirectoryNodes()
        {
            var result = new List<DirectoryNode>();
            if (DirectoryTreeView.ItemsSource is not IEnumerable<DirectoryNode> roots) return result;

            void Append(DirectoryNode node)
            {
                result.Add(node);
                if (!node.IsExpanded) return;
                foreach (DirectoryNode child in node.Children) Append(child);
            }

            foreach (DirectoryNode root in roots) Append(root);
            return result;
        }

        private IEnumerable<DirectoryNode> AllDirectoryNodes()
        {
            if (DirectoryTreeView.ItemsSource is not IEnumerable<DirectoryNode> roots)
                return Enumerable.Empty<DirectoryNode>();
            var result = new List<DirectoryNode>();
            void Append(DirectoryNode node)
            {
                result.Add(node);
                foreach (DirectoryNode child in node.Children) Append(child);
            }
            foreach (DirectoryNode root in roots) Append(root);
            return result;
        }

        private void RefreshDirectorySelectionVisuals()
        {
            foreach (DirectoryNode node in AllDirectoryNodes())
                node.IsResourceSelected = _selectedDirectoryPaths.Contains(node.FullPath);
        }

        private static TreeViewItem? FindTreeViewItem(ItemsControl parent, DirectoryNode target)
        {
            if (parent.ItemContainerGenerator.ContainerFromItem(target) is TreeViewItem direct)
                return direct;
            foreach (object item in parent.Items)
            {
                if (parent.ItemContainerGenerator.ContainerFromItem(item) is not TreeViewItem container)
                    continue;
                if (FindTreeViewItem(container, target) is { } nested) return nested;
            }
            return null;
        }

        private bool HandleDirectoryTreeKeyboard(KeyEventArgs e, bool shift)
        {
            if (FindVisualParent<TreeViewItem>(Keyboard.FocusedElement as DependencyObject) == null)
                return false;

            if (shift && (e.Key is Key.Up or Key.Down))
            {
                List<DirectoryNode> visibleNodes = VisibleDirectoryNodes();
                if (visibleNodes.Count == 0) return true;
                DirectoryNode? currentNode = DirectoryTreeView.SelectedItem as DirectoryNode;
                int currentIndex = currentNode == null ? -1 : visibleNodes.IndexOf(currentNode);
                int targetIndex = Math.Clamp(
                    currentIndex + (e.Key == Key.Down ? 1 : -1),
                    0,
                    visibleNodes.Count - 1);
                DirectoryNode target = visibleNodes[targetIndex];
                SelectDirectoryNode(target, ModifierKeys.Shift);
                if (FindTreeViewItem(DirectoryTreeView, target) is { } container)
                {
                    _suppressDirectorySelection = true;
                    container.IsSelected = true;
                    container.Focus();
                    container.BringIntoView();
                    _suppressDirectorySelection = false;
                }
                ActivateDirectoryNode(target);
                e.Handled = true;
                return true;
            }

            if (e.Key == Key.Enter && DirectoryTreeView.SelectedItem is DirectoryNode selected)
            {
                ActivateDirectoryNode(selected);
                e.Handled = true;
                return true;
            }

            return true;
        }

        private void BtnNewFolder_Click(object sender, RoutedEventArgs e)
        {
            if (!Directory.Exists(_currentDirectory) || _isWorking) return;
            string parent = DirectoryTreeView.SelectedItem is DirectoryNode { IsMediaFile: false } selected
                ? selected.FullPath
                : Directory.Exists(_browsingDirectory) ? _browsingDirectory : _currentDirectory;
            string? name = PromptForText(
                "新建文件夹",
                $"将在“{DirectoryName(parent)}”中创建文件夹。",
                "新文件夹");
            if (name == null) return;
            name = name.Trim();
            if (name.Length == 0 || name is "." or ".." || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            {
                MessageBox.Show(this, "请输入有效的文件夹名称。", "无法新建文件夹", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            string destination = Path.Combine(parent, name);
            if (Directory.Exists(destination) || File.Exists(destination))
            {
                MessageBox.Show(this, $"目标位置已经存在“{name}”。", "无法新建文件夹", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            try
            {
                Directory.CreateDirectory(destination);
                SetStatus($"已新建文件夹：{name}");
                _ = OpenDirectoryAsync(_currentDirectory, remember: false, browsingDirectory: parent);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "无法新建文件夹", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void BtnCollapseAll_Click(object sender, RoutedEventArgs e)
        {
            if (DirectoryTreeView.ItemsSource is not IEnumerable<DirectoryNode> roots) return;
            foreach (DirectoryNode root in roots) CollapseDirectoryNode(root);
            SetStatus("已收起全部目录");
        }

        private static void CollapseDirectoryNode(DirectoryNode node)
        {
            node.IsExpanded = false;
            foreach (DirectoryNode child in node.Children.Where(child => !child.IsMediaFile))
                CollapseDirectoryNode(child);
        }

        private void DirectoryTreeView_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (FindVisualParent<TreeViewItem>(e.OriginalSource as DependencyObject) is { } treeItem)
            {
                if (treeItem.DataContext is DirectoryNode node)
                {
                    _activeResourceSelectionSurface = ResourceSelectionSurface.DirectoryTree;
                    if (!_selectedDirectoryPaths.Contains(node.FullPath))
                        SelectDirectoryNode(node, ModifierKeys.None);
                }
                _suppressDirectorySelection = true;
                treeItem.IsSelected = true;
                treeItem.Focus();
                _suppressDirectorySelection = false;
            }
        }

        private void DirectoryTreeView_ContextMenuOpening(object sender, ContextMenuEventArgs e)
        {
            if (DirectoryTreeView.SelectedItem is not DirectoryNode node)
            {
                e.Handled = true;
                return;
            }

            ContextMenu menu = DirectoryTreeView.ContextMenu ?? new ContextMenu();
            menu.Items.Clear();
            var copy = new MenuItem { Header = "复制", InputGestureText = "Ctrl+C" };
            copy.Click += (_, _) => CopySelectedDirectoryResources(node);
            menu.Items.Add(copy);
            menu.Items.Add(new Separator());
            if (!node.IsMediaFile)
            {
                var create = new MenuItem { Header = "新建子文件夹…" };
                create.Click += BtnNewFolder_Click;
                menu.Items.Add(create);

                var paste = new MenuItem { Header = "粘贴到此文件夹", InputGestureText = "Ctrl+V" };
                paste.Click += async (_, _) => await PasteCopiedPhotosAsync(node.FullPath);
                menu.Items.Add(paste);

                if (!string.Equals(NormalizeDirectoryPath(node.FullPath), NormalizeDirectoryPath(_currentDirectory), StringComparison.OrdinalIgnoreCase))
                {
                    var moveFolder = new MenuItem { Header = "移动文件夹到…" };
                    moveFolder.Click += async (_, _) => await MoveDirectoryNodeAsync(node);
                    menu.Items.Add(moveFolder);
                }
            }
            else
            {
                var open = new MenuItem { Header = "查看" };
                open.Click += (_, _) => FocusDirectoryTreeMedia(node);
                menu.Items.Add(open);
                var moveFile = new MenuItem { Header = "移动到…" };
                moveFile.Click += async (_, _) => await MoveMediaNodeAsync(node);
                menu.Items.Add(moveFile);
            }

            menu.Items.Add(new Separator());
            var reveal = new MenuItem { Header = "在文件资源管理器中显示" };
            reveal.Click += (_, _) => RevealPath(node.FullPath);
            menu.Items.Add(reveal);
            var refresh = new MenuItem { Header = "刷新" };
            refresh.Click += BtnRefresh_Click;
            menu.Items.Add(refresh);
            var collapse = new MenuItem { Header = "全部收起" };
            collapse.Click += BtnCollapseAll_Click;
            menu.Items.Add(collapse);
            DirectoryTreeView.ContextMenu = menu;
        }

        private async Task MoveMediaNodeAsync(DirectoryNode node)
        {
            PhotoItem? photo = _photos.FirstOrDefault(item =>
                string.Equals(item.StableId, node.MediaStableId, StringComparison.OrdinalIgnoreCase));
            if (photo == null) return;
            string? destination = ChooseDestinationFolder($"移动“{photo.FileName}”");
            if (destination == null || !ConfirmMove(photo.FileName, destination)) return;
            try
            {
                MovePhotoResources(photo, destination);
                MigratePhotoState(photo, destination, Path.Combine(destination, photo.FileName));
                SetStatus($"已移动：{photo.FileName} → {DirectoryName(destination)}");
                await OpenDirectoryAsync(_currentDirectory, remember: false, browsingDirectory: destination);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "无法移动照片", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private async Task MoveDirectoryNodeAsync(DirectoryNode node)
        {
            string source = NormalizeDirectoryPath(node.FullPath);
            string? destinationDirectory = ChooseDestinationFolder($"移动文件夹“{node.Name}”");
            if (destinationDirectory == null || !ConfirmMove(node.Name, destinationDirectory)) return;
            try
            {
                destinationDirectory = NormalizeDirectoryPath(destinationDirectory);
                if (!IsSameOrDescendant(destinationDirectory, _currentDirectory))
                    throw new InvalidOperationException("目标位置必须位于当前打开的图库根目录内。");
                if (IsSameOrDescendant(destinationDirectory, source))
                    throw new InvalidOperationException("不能把文件夹移动到它自己或它的子目录中。");
                string destination = Path.Combine(destinationDirectory, Path.GetFileName(source));
                if (Directory.Exists(destination) || File.Exists(destination))
                    throw new IOException($"目标位置已经存在“{Path.GetFileName(source)}”。");

                List<PhotoItem> affected = _photos.Where(photo => IsSameOrDescendant(photo.Directory, source)).ToList();
                Directory.Move(source, destination);
                foreach (PhotoItem photo in affected)
                {
                    string relativeDirectory = Path.GetRelativePath(source, photo.Directory);
                    string newDirectory = relativeDirectory == "."
                        ? destination
                        : Path.Combine(destination, relativeDirectory);
                    string newPath = Path.Combine(newDirectory, photo.FileName);
                    MigratePhotoState(photo, newDirectory, newPath);
                }
                SetStatus($"已移动文件夹：{node.Name} → {DirectoryName(destinationDirectory)}");
                await OpenDirectoryAsync(_currentDirectory, remember: false, browsingDirectory: destination);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "无法移动文件夹", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private string? ChooseDestinationFolder(string title)
        {
            var dialog = new OpenFolderDialog
            {
                Title = title,
                InitialDirectory = Directory.Exists(_browsingDirectory) ? _browsingDirectory : _currentDirectory
            };
            if (dialog.ShowDialog() != true) return null;
            string destination = NormalizeDirectoryPath(dialog.FolderName);
            if (!IsSameOrDescendant(destination, _currentDirectory))
            {
                MessageBox.Show(this, "目标位置必须位于当前打开的图库根目录内。", "不能移动", MessageBoxButton.OK, MessageBoxImage.Warning);
                return null;
            }
            return destination;
        }

        private bool ConfirmMove(string name, string destination) =>
            MessageBox.Show(
                this,
                $"把“{name}”移动到：\n{destination}",
                "确认移动",
                MessageBoxButton.OKCancel,
                MessageBoxImage.Question) == MessageBoxResult.OK;

        private static void MovePhotoResources(PhotoItem photo, string destinationDirectory)
        {
            var moved = new List<(string Source, string Destination)>();
            try
            {
                foreach (string source in photo.OriginalResourcePaths)
                {
                    string destination = Path.Combine(destinationDirectory, Path.GetFileName(source));
                    if (string.Equals(Path.GetFullPath(source), Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("文件已经位于所选目录中。");
                    if (File.Exists(destination) || Directory.Exists(destination))
                        throw new IOException($"目标位置已经存在“{Path.GetFileName(source)}”。");
                    File.Move(source, destination);
                    moved.Add((source, destination));
                }
            }
            catch
            {
                foreach (var pair in moved.AsEnumerable().Reverse())
                {
                    try { if (File.Exists(pair.Destination)) File.Move(pair.Destination, pair.Source); } catch { }
                }
                throw;
            }
        }

        private void MigratePhotoState(PhotoItem photo, string newDirectory, string newPath)
        {
            _favoriteStore.SetFavorite(newDirectory, photo.FileName, photo.IsFavorite);
            _favoriteStore.SetFavorite(photo.Directory, photo.FileName, false);
            foreach (string tag in photo.Tags) _tagStore.AddTag(newDirectory, photo.FileName, tag);
            _tagStore.RemoveAll(photo.Directory, photo.FileName);
            _holdFrameStore.Set(newPath, photo.HoldFrameTime);
            _holdFrameStore.Remove(photo.FilePath);
            _rotationStore.Set(newPath, photo.SavedRotationQuarterTurns);
            _rotationStore.Remove(photo.FilePath);
        }

        private void CopySelectedPhotos(PhotoItem? preferredPhoto = null)
        {
            if (_isWorking) return;
            _activeResourceSelectionSurface = ResourceSelectionSurface.Gallery;
            ClearDirectorySelection();
            if (preferredPhoto != null && !_selectedPhotoIds.Contains(preferredPhoto.StableId))
            {
                SelectSinglePhoto(preferredPhoto);
                SetFocusedPhoto(preferredPhoto);
                RefreshPhotoSelectionVisuals();
            }
            if (_selectedPhotoIds.Count == 0 && _focusedPhotoId != null)
                _selectedPhotoIds.Add(_focusedPhotoId);

            List<PhotoItem> selected = _visiblePhotos
                .Where(photo => _selectedPhotoIds.Contains(photo.StableId))
                .ToList();
            var bundles = selected
                .Select(photo => photo.OriginalResourcePaths.Where(File.Exists).ToList())
                .Where(bundle => bundle.Count > 0)
                .ToList();
            if (bundles.Count == 0)
            {
                SetStatus("请先选择要复制的照片");
                return;
            }

            WriteResourceBundlesToClipboard(bundles);
        }

        private void CopyActiveResourceSelection()
        {
            if (_activeResourceSelectionSurface == ResourceSelectionSurface.DirectoryTree)
                CopySelectedDirectoryResources();
            else
                CopySelectedPhotos();
        }

        private void CopySelectedDirectoryResources(DirectoryNode? preferredNode = null)
        {
            if (_isWorking) return;
            _activeResourceSelectionSurface = ResourceSelectionSurface.DirectoryTree;
            _selectedPhotoIds.Clear();
            _selectionAnchorId = null;
            RefreshPhotoSelectionVisuals();
            if (preferredNode != null && !_selectedDirectoryPaths.Contains(preferredNode.FullPath))
            {
                SelectSingleDirectoryNode(preferredNode);
                RefreshDirectorySelectionVisuals();
            }

            List<DirectoryNode> selectedNodes = AllDirectoryNodes()
                .Where(node => _selectedDirectoryPaths.Contains(node.FullPath))
                .ToList();
            List<string> topDirectories = selectedNodes
                .Where(node => !node.IsMediaFile && Directory.Exists(node.FullPath))
                .Select(node => NormalizeDirectoryPath(node.FullPath))
                .OrderBy(path => path.Length)
                .Aggregate(new List<string>(), (result, path) =>
                {
                    if (!result.Any(parent => IsSameOrDescendant(path, parent))) result.Add(path);
                    return result;
                });

            var bundles = topDirectories.Select(path => new List<string> { path }).ToList();
            foreach (DirectoryNode node in selectedNodes.Where(node => node.IsMediaFile))
            {
                if (topDirectories.Any(parent => IsSameOrDescendant(node.FullPath, parent))) continue;
                PhotoItem? photo = _photos.FirstOrDefault(item => string.Equals(
                    item.StableId, node.MediaStableId, StringComparison.OrdinalIgnoreCase));
                if (photo == null) continue;
                List<string> resources = photo.OriginalResourcePaths.Where(File.Exists).ToList();
                if (resources.Count > 0) bundles.Add(resources);
            }

            if (bundles.Count == 0)
            {
                SetStatus("请先在资源管理器中选择要复制的项目");
                return;
            }
            WriteResourceBundlesToClipboard(bundles);
        }

        private void WriteResourceBundlesToClipboard(List<List<string>> bundles)
        {
            var paths = bundles.SelectMany(bundle => bundle)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            try
            {
                var fileDropList = new System.Collections.Specialized.StringCollection();
                fileDropList.AddRange(paths.ToArray());
                Clipboard.SetFileDropList(fileDropList);
                _copiedResourceBundles = bundles;
                _copiedClipboardPaths = paths
                    .Select(Path.GetFullPath)
                    .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                    .ToList();
                SetStatus($"已复制 {bundles.Count:N0} 个项目，可在目标目录按 Ctrl+V 粘贴");
            }
            catch (Exception ex)
            {
                SetStatus($"无法写入剪贴板：{ex.Message}");
            }
        }

        private async Task PasteCopiedPhotosAsync(string? destinationDirectory = null)
        {
            if (_isWorking) return;
            string destination = NormalizeDirectoryPath(
                Directory.Exists(destinationDirectory) ? destinationDirectory! : _browsingDirectory);
            if (!Directory.Exists(destination) || !IsSameOrDescendant(destination, _currentDirectory))
            {
                SetStatus("请选择当前图库中的目标目录");
                return;
            }

            List<List<string>> bundles = ClipboardResourceBundles();
            if (bundles.Count == 0)
            {
                SetStatus("剪贴板中没有可粘贴的文件夹、照片或视频");
                return;
            }

            try
            {
                SetWorking(true, 0, Math.Max(1, bundles.Count));
                int copied = await Task.Run(() => CopyResourceBundles(bundles, destination));
                _selectedPhotoIds.Clear();
                _selectionAnchorId = null;
                _selectedDirectoryPaths.Clear();
                _directorySelectionAnchorPath = null;
                await OpenDirectoryAsync(_currentDirectory, remember: false, browsingDirectory: destination);
                SetStatus($"已粘贴 {copied:N0} 个项目到 {DirectoryName(destination)}");
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "无法粘贴照片", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                SetWorking(false);
            }
        }

        private List<List<string>> ClipboardResourceBundles()
        {
            try
            {
                if (!Clipboard.ContainsFileDropList()) return new List<List<string>>();
                List<string> paths = Clipboard.GetFileDropList().Cast<string>()
                    .Where(path => File.Exists(path) || Directory.Exists(path))
                    .Select(Path.GetFullPath)
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToList();
                List<string> signature = paths
                    .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                    .ToList();
                if (_copiedResourceBundles.Count > 0 &&
                    signature.SequenceEqual(_copiedClipboardPaths, StringComparer.OrdinalIgnoreCase))
                    return _copiedResourceBundles;
                return GroupClipboardResources(paths);
            }
            catch
            {
                return new List<List<string>>();
            }
        }

        private static List<List<string>> GroupClipboardResources(IEnumerable<string> paths)
        {
            List<string> directories = paths.Where(Directory.Exists)
                .Select(NormalizeDirectoryPath)
                .ToList();
            List<string> media = paths
                .Where(path => LivePhotoExtractor.IsSupportedImage(path) || LivePhotoExtractor.IsSupportedVideo(path))
                .ToList();
            var usedVideos = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var bundles = directories.Select(path => new List<string> { path }).ToList();
            foreach (string image in media.Where(LivePhotoExtractor.IsSupportedImage))
            {
                var bundle = new List<string> { image };
                string? sidecar = media.FirstOrDefault(path =>
                    Path.GetExtension(path).Equals(".mov", StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(Path.GetFileNameWithoutExtension(path), Path.GetFileNameWithoutExtension(image), StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(Path.GetDirectoryName(path), Path.GetDirectoryName(image), StringComparison.OrdinalIgnoreCase) &&
                    !usedVideos.Contains(path));
                if (sidecar != null)
                {
                    bundle.Add(sidecar);
                    usedVideos.Add(sidecar);
                }
                bundles.Add(bundle);
            }
            bundles.AddRange(media
                .Where(LivePhotoExtractor.IsSupportedVideo)
                .Where(path => !usedVideos.Contains(path))
                .Select(path => new List<string> { path }));
            return bundles;
        }

        private static int CopyResourceBundles(IReadOnlyList<List<string>> bundles, string destinationDirectory)
        {
            var copiedPaths = new List<string>();
            try
            {
                foreach (List<string> sources in bundles)
                {
                    foreach (string sourceDirectory in sources.Where(Directory.Exists))
                    {
                        if (IsSameOrDescendant(destinationDirectory, sourceDirectory))
                            throw new InvalidOperationException("不能把文件夹复制到它自己或它的子目录中。");
                    }
                    List<string> destinations = UniqueCopyDestinations(sources, destinationDirectory);
                    for (int index = 0; index < sources.Count; index++)
                    {
                        if (Directory.Exists(sources[index]))
                            CopyDirectoryRecursively(sources[index], destinations[index]);
                        else
                            File.Copy(sources[index], destinations[index]);
                        copiedPaths.Add(destinations[index]);
                    }
                }
                return bundles.Count;
            }
            catch
            {
                foreach (string copiedPath in copiedPaths.AsEnumerable().Reverse())
                {
                    try
                    {
                        if (File.Exists(copiedPath)) File.Delete(copiedPath);
                        else if (Directory.Exists(copiedPath)) Directory.Delete(copiedPath, recursive: true);
                    }
                    catch { }
                }
                throw;
            }
        }

        private static List<string> UniqueCopyDestinations(IReadOnlyList<string> sources, string destinationDirectory)
        {
            for (int copyNumber = 0; copyNumber <= 10_000; copyNumber++)
            {
                string suffix = copyNumber switch
                {
                    0 => string.Empty,
                    1 => " 副本",
                    _ => $" 副本 {copyNumber}"
                };
                List<string> candidates = sources.Select(source => Path.Combine(
                    destinationDirectory,
                    Directory.Exists(source)
                        ? Path.GetFileName(source) + suffix
                        : Path.GetFileNameWithoutExtension(source) + suffix + Path.GetExtension(source))).ToList();
                if (candidates.Distinct(StringComparer.OrdinalIgnoreCase).Count() == candidates.Count &&
                    candidates.All(candidate => !File.Exists(candidate) && !Directory.Exists(candidate)))
                    return candidates;
            }
            return sources.Select(source => Path.Combine(
                destinationDirectory,
                Directory.Exists(source)
                    ? $"{Path.GetFileName(source)}-{Guid.NewGuid():N}"
                    : $"{Path.GetFileNameWithoutExtension(source)}-{Guid.NewGuid():N}{Path.GetExtension(source)}")).ToList();
        }

        private static void CopyDirectoryRecursively(string sourceDirectory, string destinationDirectory)
        {
            Directory.CreateDirectory(destinationDirectory);
            foreach (string file in Directory.EnumerateFiles(sourceDirectory))
                File.Copy(file, Path.Combine(destinationDirectory, Path.GetFileName(file)));
            foreach (string directory in Directory.EnumerateDirectories(sourceDirectory))
                CopyDirectoryRecursively(directory, Path.Combine(destinationDirectory, Path.GetFileName(directory)));
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

        private void RevealPath(string path)
        {
            try
            {
                var startInfo = new ProcessStartInfo("explorer.exe") { UseShellExecute = true };
                if (Directory.Exists(path))
                    startInfo.ArgumentList.Add(path);
                else
                    startInfo.ArgumentList.Add($"/select,{path}");
                Process.Start(startInfo);
            }
            catch (Exception ex)
            {
                SetStatus($"无法在文件资源管理器中显示：{ex.Message}");
            }
        }

        private string? PromptForText(string title, string message, string initialValue)
        {
            var input = new TextBox
            {
                Text = initialValue,
                MinWidth = 320,
                Margin = new Thickness(0, 8, 0, 14),
                Padding = new Thickness(7, 5)
            };
            var accept = new Button
            {
                Content = "创建",
                IsDefault = true,
                MinWidth = 76,
                Margin = new Thickness(0, 0, 6, 0),
                Style = (Style)FindResource("FlatButtonStyle")
            };
            var cancel = new Button
            {
                Content = "取消",
                IsCancel = true,
                MinWidth = 76,
                Style = (Style)FindResource("FlatButtonStyle")
            };
            var buttons = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right
            };
            buttons.Children.Add(accept);
            buttons.Children.Add(cancel);
            var content = new StackPanel { Margin = new Thickness(18) };
            content.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
            content.Children.Add(input);
            content.Children.Add(buttons);
            var dialog = new Window
            {
                Title = title,
                Owner = this,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                SizeToContent = SizeToContent.WidthAndHeight,
                ResizeMode = ResizeMode.NoResize,
                Content = content,
                Background = (Brush)FindResource("CardBgBrush"),
                Foreground = (Brush)FindResource("TextBrush")
            };
            accept.Click += (_, _) => dialog.DialogResult = true;
            dialog.Loaded += (_, _) =>
            {
                input.Focus();
                input.SelectAll();
            };
            return dialog.ShowDialog() == true ? input.Text : null;
        }

        private RotationSaveChoice ShowRotationSaveChoice(bool protectsMotion, bool canOverwrite)
        {
            RotationSaveChoice choice = RotationSaveChoice.Cancel;
            var message = new TextBlock
            {
                Text = protectsMotion
                    ? "“保存实况编辑”会像手机相册一样保存可恢复的查看方向，并让封面与实况视频同步旋转；原始 JPG/HEIC、内嵌视频和配套 MOV 不会被改写。也可以另存为不含动态视频的静态副本。"
                    : canOverwrite
                        ? "覆盖会直接改写磁盘上的原图；另存为会保留原文件。"
                        : "Windows 当前不能直接写回这种图片格式，请另存为 JPG、PNG、BMP 或 TIFF。",
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 440,
                Margin = new Thickness(0, 0, 0, 16)
            };
            var buttons = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right
            };
            Button? saveAdjustment = null;
            if (protectsMotion)
            {
                saveAdjustment = new Button
                {
                    Content = "保存实况编辑",
                    IsDefault = true,
                    MinWidth = 122,
                    Margin = new Thickness(0, 0, 6, 0),
                    Style = (Style)FindResource("FlatButtonStyle")
                };
                buttons.Children.Add(saveAdjustment);
            }
            var saveAs = new Button
            {
                Content = protectsMotion ? "另存为静态副本…" : "另存为…",
                IsDefault = !protectsMotion,
                MinWidth = 112,
                Margin = new Thickness(0, 0, 6, 0),
                Style = (Style)FindResource("FlatButtonStyle")
            };
            buttons.Children.Add(saveAs);
            Button? overwrite = null;
            if (canOverwrite)
            {
                overwrite = new Button
                {
                    Content = "覆盖原图",
                    MinWidth = 92,
                    Margin = new Thickness(0, 0, 6, 0),
                    Style = (Style)FindResource("FlatButtonStyle")
                };
                buttons.Children.Add(overwrite);
            }
            var cancel = new Button
            {
                Content = "取消",
                IsCancel = true,
                MinWidth = 76,
                Style = (Style)FindResource("FlatButtonStyle")
            };
            buttons.Children.Add(cancel);
            var content = new StackPanel { Margin = new Thickness(18) };
            content.Children.Add(message);
            content.Children.Add(buttons);
            var dialog = new Window
            {
                Title = "保存编辑",
                Owner = this,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                SizeToContent = SizeToContent.WidthAndHeight,
                ResizeMode = ResizeMode.NoResize,
                Content = content,
                Background = (Brush)FindResource("CardBgBrush"),
                Foreground = (Brush)FindResource("TextBrush")
            };
            if (saveAdjustment != null)
            {
                saveAdjustment.Click += (_, _) =>
                {
                    choice = RotationSaveChoice.SaveAdjustment;
                    dialog.DialogResult = true;
                };
            }
            saveAs.Click += (_, _) =>
            {
                choice = RotationSaveChoice.SaveAs;
                dialog.DialogResult = true;
            };
            if (overwrite != null)
            {
                overwrite.Click += (_, _) =>
                {
                    choice = RotationSaveChoice.Overwrite;
                    dialog.DialogResult = true;
                };
            }
            dialog.ShowDialog();
            return choice;
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

        private async Task OpenDirectoryAsync(
            string path,
            bool remember = true,
            string? browsingDirectory = null)
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
            string requestedBrowsingDirectory = string.IsNullOrWhiteSpace(browsingDirectory)
                ? _currentDirectory
                : NormalizeDirectoryPath(browsingDirectory);
            _browsingDirectory = Directory.Exists(requestedBrowsingDirectory)
                && IsSameOrDescendant(requestedBrowsingDirectory, _currentDirectory)
                    ? requestedBrowsingDirectory
                    : _currentDirectory;
            if (remember) _recentFolders.Add(_currentDirectory);
            _focusedPhotoId = null;
            _previousFocusedPhotoId = null;
            _selectedPhotoIds.Clear();
            _selectionAnchorId = null;
            _selectedDirectoryPaths.Clear();
            _directorySelectionAnchorPath = null;
            _activeResourceSelectionSurface = ResourceSelectionSurface.Gallery;
            _selectedTag = null;
            _cardMap.Clear();
            _thumbnailMap.Clear();
            ThumbnailPanel.Children.Clear();
            CurrentPathText.Text = _currentDirectory;
            LibraryPathText.Text = _browsingDirectory;
            SetStatus("正在扫描照片与视频…");
            SetWorking(true, 0, 1);

            try
            {
                const bool recursively = true;
                var scan = await Task.Run(() => EnumerateLibrary(_currentDirectory, recursively, token), token);
                token.ThrowIfCancellationRequested();
                var files = scan.Files;
                _directories = scan.Directories;
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
                    photo.SavedRotationQuarterTurns = _rotationStore.Get(photo.FilePath);
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
            long fileSize = info.Exists ? info.Length : 0;
            long companionSize = companion is { Length: > 0 } companionPath && File.Exists(companionPath)
                ? new FileInfo(companionPath).Length
                : 0;
            return new PhotoItem
            {
                FilePath = path,
                FileName = Path.GetFileName(path),
                Directory = Path.GetDirectoryName(path) ?? _currentDirectory,
                CompanionVideoPath = companion,
                MediaKind = kind,
                FileSize = fileSize,
                OriginalResourceFileSize = fileSize + companionSize,
                ModifiedAt = info.Exists ? info.LastWriteTime : DateTime.MinValue,
                TimelineDate = info.Exists ? info.LastWriteTime : DateTime.MinValue
            };
        }

        private static (List<string> Files, List<string> Directories) EnumerateLibrary(
            string root,
            bool recursively,
            CancellationToken token)
        {
            var result = new List<string>();
            var directories = new List<string>();
            var pending = new Stack<string>();
            pending.Push(root);
            while (pending.Count > 0)
            {
                token.ThrowIfCancellationRequested();
                string directory = pending.Pop();
                directories.Add(NormalizeDirectoryPath(directory));
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
            return (result, directories);
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

            foreach (string discoveredDirectory in _directories)
            {
                string directory = NormalizeDirectoryPath(discoveredDirectory);
                if (!IsSameOrDescendant(directory, rootPath) || nodes.ContainsKey(directory)) continue;
                nodes[directory] = new DirectoryNode
                {
                    Name = DirectoryName(directory),
                    FullPath = directory
                };
            }

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
                directNode.PhotoSize += photo.OriginalResourceFileSize;

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
            CalculateTotalPhotoCount(nodes[rootPath]);

            foreach (PhotoItem photo in _photos)
            {
                string directory = NormalizeDirectoryPath(photo.Directory);
                if (!nodes.TryGetValue(directory, out DirectoryNode? parent)) continue;
                parent.Children.Add(new DirectoryNode
                {
                    Name = photo.FileName,
                    FullPath = photo.FilePath,
                    IsMediaFile = true,
                    IsVideo = photo.IsVideo,
                    MediaStableId = photo.StableId
                });
            }
            SortDirectoryNodes(nodes[rootPath]);

            var availablePaths = nodes.Values.Select(node => node.FullPath)
                .Concat(nodes.Values.SelectMany(node => node.Children)
                    .Where(node => node.IsMediaFile)
                    .Select(node => node.FullPath))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            _selectedDirectoryPaths.RemoveWhere(path => !availablePaths.Contains(path));
            if (_directorySelectionAnchorPath != null && !availablePaths.Contains(_directorySelectionAnchorPath))
                _directorySelectionAnchorPath = null;

            if (!nodes.ContainsKey(_browsingDirectory)) _browsingDirectory = rootPath;
            foreach (DirectoryNode node in nodes.Values)
            {
                node.IsSelected = string.Equals(node.FullPath, _browsingDirectory, StringComparison.OrdinalIgnoreCase);
                node.IsResourceSelected = _selectedDirectoryPaths.Contains(node.FullPath);
                node.IsExpanded = string.Equals(node.FullPath, rootPath, StringComparison.OrdinalIgnoreCase)
                    || IsSameOrDescendant(_browsingDirectory, node.FullPath);
            }
            foreach (DirectoryNode mediaNode in nodes.Values.SelectMany(node => node.Children)
                         .Where(node => node.IsMediaFile))
                mediaNode.IsResourceSelected = _selectedDirectoryPaths.Contains(mediaNode.FullPath);
            _suppressDirectorySelection = true;
            DirectoryTreeView.ItemsSource = new[] { nodes[rootPath] };
            _suppressDirectorySelection = false;
        }

        private static void SortDirectoryNodes(DirectoryNode node)
        {
            node.Children.Sort((left, right) =>
            {
                int typeOrder = left.IsMediaFile.CompareTo(right.IsMediaFile);
                return typeOrder != 0
                    ? typeOrder
                    : StringComparer.CurrentCultureIgnoreCase.Compare(left.Name, right.Name);
            });
            foreach (DirectoryNode child in node.Children.Where(child => !child.IsMediaFile))
                SortDirectoryNodes(child);
        }

        private static int CalculateTotalPhotoCount(DirectoryNode node)
        {
            if (node.IsMediaFile) return 0;
            node.TotalPhotoCount = node.PhotoCount;
            node.TotalPhotoSize = node.PhotoSize;
            foreach (DirectoryNode child in node.Children)
            {
                node.TotalPhotoCount += CalculateTotalPhotoCount(child);
                node.TotalPhotoSize += child.TotalPhotoSize;
            }
            return node.TotalPhotoCount;
        }

        private void FocusDirectoryTreeMedia(DirectoryNode node)
        {
            PhotoItem? photo = _photos.FirstOrDefault(item =>
                string.Equals(item.StableId, node.MediaStableId, StringComparison.OrdinalIgnoreCase));
            if (photo == null) return;

            _browsingDirectory = NormalizeDirectoryPath(photo.Directory);
            _filter = LibraryFilter.All;
            _selectedTag = null;
            SearchBox.Text = string.Empty;
            LibraryPathText.Text = _browsingDirectory;
            UpdateFilterVisuals();
            RenderGallery();
            SetFocusedPhoto(photo);
            RefreshPhotoSelectionVisuals();
            SetStatus(_selectedDirectoryPaths.Count > 1
                ? $"已选择 {_selectedDirectoryPaths.Count:N0} 个资源"
                : $"当前照片：{photo.FileName}");
            Dispatcher.BeginInvoke(new Action(() => ScrollToPhoto(photo.StableId)));
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
                        card.CopyRequested += OnCopyRequested;
                        card.MoveRequested += OnMoveRequested;
                        card.RevealRequested += OnRevealRequested;
                        card.TrashRequested += OnTrashRequested;
                        _cardMap[photo.StableId] = card;
                        if (thumbnailReady) card.SetLoaded(thumbnail, photo.IsLivePhoto);
                    }
                    card.Margin = new Thickness(IsShowcaseMode ? 4 : 4, 0, 4, IsShowcaseMode ? 18 : 8);
                    card.SetDisplaySize(cardWidth, IsShowcaseMode);
                    card.SetFocused(string.Equals(photo.StableId, _focusedPhotoId, StringComparison.OrdinalIgnoreCase));
                    card.SetResourceSelected(_selectedPhotoIds.Contains(photo.StableId));
                    panel.Children.Add(card);
                }
                ThumbnailPanel.Children.Add(panel);
            }
            UpdateCounts();
            UpdateVisibleCountText();
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
            if (photo != null)
            {
                ModifierKeys modifiers = sender is ThumbnailCard card
                    ? card.LastSelectionModifiers
                    : ModifierKeys.None;
                SelectPhoto(photo, modifiers);
            }
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

        private void SelectPhoto(PhotoItem photo, ModifierKeys modifiers)
        {
            _activeResourceSelectionSurface = ResourceSelectionSurface.Gallery;
            ClearDirectorySelection();
            bool extendRange = modifiers.HasFlag(ModifierKeys.Shift);
            bool toggle = modifiers.HasFlag(ModifierKeys.Control);
            if (extendRange && _selectionAnchorId != null)
            {
                int anchor = _visiblePhotos.FindIndex(item =>
                    string.Equals(item.StableId, _selectionAnchorId, StringComparison.OrdinalIgnoreCase));
                int target = _visiblePhotos.FindIndex(item =>
                    string.Equals(item.StableId, photo.StableId, StringComparison.OrdinalIgnoreCase));
                if (anchor >= 0 && target >= 0)
                {
                    if (!toggle) _selectedPhotoIds.Clear();
                    int start = Math.Min(anchor, target);
                    int end = Math.Max(anchor, target);
                    for (int index = start; index <= end; index++)
                        _selectedPhotoIds.Add(_visiblePhotos[index].StableId);
                }
                else
                {
                    SelectSinglePhoto(photo);
                }
            }
            else if (toggle)
            {
                if (!_selectedPhotoIds.Add(photo.StableId))
                    _selectedPhotoIds.Remove(photo.StableId);
                _selectionAnchorId = photo.StableId;
            }
            else
            {
                SelectSinglePhoto(photo);
            }

            SetFocusedPhoto(photo);
            RefreshPhotoSelectionVisuals();
            SetStatus(_selectedPhotoIds.Count > 1
                ? $"已选择 {_selectedPhotoIds.Count:N0} 张照片"
                : $"当前照片：{photo.FileName}");
        }

        private void SelectSinglePhoto(PhotoItem photo)
        {
            _selectedPhotoIds.Clear();
            _selectedPhotoIds.Add(photo.StableId);
            _selectionAnchorId = photo.StableId;
        }

        private void ClearPhotoSelection()
        {
            _selectedPhotoIds.Clear();
            _selectionAnchorId = null;
            RefreshPhotoSelectionVisuals();
        }

        private void SelectAllVisiblePhotos()
        {
            if (_visiblePhotos.Count == 0) return;
            _activeResourceSelectionSurface = ResourceSelectionSurface.Gallery;
            ClearDirectorySelection();
            _selectedPhotoIds.Clear();
            foreach (PhotoItem photo in _visiblePhotos) _selectedPhotoIds.Add(photo.StableId);
            _selectionAnchorId = _visiblePhotos[0].StableId;
            if (_focusedPhotoId == null) SetFocusedPhoto(_visiblePhotos[0]);
            RefreshPhotoSelectionVisuals();
            SetStatus($"已选择当前列表中的 {_selectedPhotoIds.Count:N0} 张照片");
        }

        private void RefreshPhotoSelectionVisuals()
        {
            foreach (var pair in _cardMap)
                pair.Value.SetResourceSelected(_selectedPhotoIds.Contains(pair.Key));
            UpdateVisibleCountText();
        }

        private void UpdateVisibleCountText()
        {
            VisibleCountText.Text = _selectedPhotoIds.Count > 0
                ? $"已选 {_selectedPhotoIds.Count:N0} 个 · 当前显示 {_visiblePhotos.Count:N0} 个"
                : $"当前显示 {_visiblePhotos.Count:N0} 个";
        }

        private void OnCopyRequested(object? sender, string filePath)
        {
            PhotoItem? photo = _photos.FirstOrDefault(item =>
                string.Equals(item.FilePath, filePath, StringComparison.OrdinalIgnoreCase));
            CopySelectedPhotos(photo);
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

        private async void OnMoveRequested(object? sender, string filePath)
        {
            PhotoItem? photo = _photos.FirstOrDefault(item =>
                string.Equals(item.FilePath, filePath, StringComparison.OrdinalIgnoreCase));
            if (photo == null) return;
            await MoveMediaNodeAsync(new DirectoryNode
            {
                Name = photo.FileName,
                FullPath = photo.FilePath,
                IsMediaFile = true,
                MediaStableId = photo.StableId
            });
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
            _selectedPhotoIds.Clear();
            _selectionAnchorId = null;
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
            if (IsLoaded)
            {
                _selectedPhotoIds.Clear();
                _selectionAnchorId = null;
                RenderGallery();
            }
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
            ResetViewerRotation();
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
            int videoRotation = ((photo.SavedRotationQuarterTurns + _viewerRotationQuarterTurns) % 4 + 4) % 4;
            if (videoRotation != 0)
            {
                _currentVlcMedia.AddOption(":video-filter=transform");
                _currentVlcMedia.AddOption($":transform-type={videoRotation * 90}");
            }
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

        private void ViewerRotateLeft_Click(object sender, RoutedEventArgs e) => RotateViewer(-1);
        private void ViewerRotateRight_Click(object sender, RoutedEventArgs e) => RotateViewer(1);

        private void RotateViewer(int quarterTurns)
        {
            if (_isWorking) return;
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            if (photo.IsVideo || ViewerVideoView.Visibility == Visibility.Visible) return;
            _viewerRotationQuarterTurns = (_viewerRotationQuarterTurns + quarterTurns) % 4;
            ApplyViewerRotation(photo);
            ResetViewerTransform();
            UpdateViewerZoomControls();
        }

        private void ResetViewerRotation()
        {
            _viewerRotationQuarterTurns = 0;
            if (!IsLoaded) return;
            if (_viewerIndex >= 0 && _viewerIndex < _visiblePhotos.Count)
                ApplyViewerRotation(_visiblePhotos[_viewerIndex]);
            else
                ViewerRotateTransform.Angle = 0;
        }

        private void ApplyViewerRotation(PhotoItem photo)
        {
            int turns = ((photo.SavedRotationQuarterTurns + _viewerRotationQuarterTurns) % 4 + 4) % 4;
            ViewerRotateTransform.Angle = turns * 90;
        }

        private async void ViewerSaveRotation_Click(object sender, RoutedEventArgs e)
        {
            if (_isWorking) return;
            if (_viewerIndex < 0 || _viewerIndex >= _visiblePhotos.Count) return;
            int pendingTurns = ((_viewerRotationQuarterTurns % 4) + 4) % 4;
            if (pendingTurns == 0) return;
            PhotoItem photo = _visiblePhotos[_viewerIndex];
            int turns = ((photo.SavedRotationQuarterTurns + _viewerRotationQuarterTurns) % 4 + 4) % 4;
            bool protectsMotion = photo.IsLivePhoto
                || !photo.IsLiveStatusKnown
                || !string.IsNullOrWhiteSpace(photo.CompanionVideoPath)
                || photo.SavedRotationQuarterTurns != 0;
            bool canOverwrite = !protectsMotion && ImageRotationService.CanWrite(photo.FilePath);
            RotationSaveChoice choice = ShowRotationSaveChoice(protectsMotion, canOverwrite);
            if (choice == RotationSaveChoice.Cancel) return;

            if (choice == RotationSaveChoice.SaveAdjustment)
            {
                photo.SavedRotationQuarterTurns = turns;
                _rotationStore.Set(photo.FilePath, turns);
                if (_cardMap.TryGetValue(photo.StableId, out ThumbnailCard? card))
                    card.SetSavedRotation(turns);
                ResetViewerRotation();
                SetStatus(turns == 0
                    ? $"已恢复原始方向：{photo.FileName}"
                    : $"已保存可恢复的实况旋转：{photo.FileName}");
                MessageBox.Show(
                    this,
                    "旋转方向已保存，封面和实况视频会同步显示；原始实况资源保持不变，可随时旋转回来。",
                    "实况旋转已保存",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            bool overwrite = choice == RotationSaveChoice.Overwrite;
            string destination = photo.FilePath;
            if (!overwrite)
            {
                string sourceExtension = Path.GetExtension(photo.FilePath).ToLowerInvariant();
                string extension = ImageRotationService.CanWrite(photo.FilePath) ? sourceExtension : ".jpg";
                var saveDialog = new SaveFileDialog
                {
                    Title = protectsMotion ? "另存为旋转后的静态副本" : "另存为旋转后的图片",
                    InitialDirectory = photo.Directory,
                    FileName = $"{Path.GetFileNameWithoutExtension(photo.FileName)}_已旋转{extension}",
                    DefaultExt = extension,
                    AddExtension = true,
                    Filter = "JPEG 图片|*.jpg;*.jpeg|PNG 图片|*.png|TIFF 图片|*.tif;*.tiff|BMP 图片|*.bmp"
                };
                if (saveDialog.ShowDialog(this) != true) return;
                destination = saveDialog.FileName;
                if (string.Equals(Path.GetFullPath(destination), Path.GetFullPath(photo.FilePath), StringComparison.OrdinalIgnoreCase))
                {
                    string warning = protectsMotion
                        ? "实况照片不能用静态副本覆盖原文件，请换一个文件名。"
                        : "如需改写原图，请使用“覆盖原图”；另存为需要使用不同的文件名。";
                    MessageBox.Show(this, warning, "请选择其他文件名", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
            }

            try
            {
                SetWorking(true);
                BtnViewerSaveRotation.Content = "…";
                await Task.Run(() => ImageRotationService.SaveRotated(
                    photo.FilePath,
                    destination,
                    turns,
                    overwrite));
                if (overwrite && photo.SavedRotationQuarterTurns != 0)
                {
                    _rotationStore.Remove(photo.FilePath);
                    photo.SavedRotationQuarterTurns = 0;
                }
                ResetViewerRotation();
                string savedDirectory = Path.GetDirectoryName(destination) ?? photo.Directory;
                string browseAfterSave = IsSameOrDescendant(savedDirectory, _currentDirectory)
                    ? savedDirectory
                    : photo.Directory;
                await OpenDirectoryAsync(_currentDirectory, remember: false, browsingDirectory: browseAfterSave);
                MessageBox.Show(this, $"旋转后的图片已保存：\n{destination}", "保存完成", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "保存旋转结果失败", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                BtnViewerSaveRotation.Content = "✓";
                SetWorking(false);
            }
        }

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
            bool canRotate = canZoom && _viewerIndex >= 0 && _viewerIndex < _visiblePhotos.Count && !_visiblePhotos[_viewerIndex].IsVideo;
            BtnViewerRotateLeft.IsEnabled = canRotate;
            BtnViewerRotateRight.IsEnabled = canRotate;
            BtnViewerSaveRotation.IsEnabled = canRotate && ((_viewerRotationQuarterTurns % 4) + 4) % 4 != 0;
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
            _selectedPhotoIds.Clear();
            _selectionAnchorId = null;
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
            if (_isSidebarVisible)
            {
                double maximumWidth = EffectiveMaximumSidebarWidth();
                SidebarColumn.MinWidth = MinimumSidebarWidth;
                SidebarColumn.MaxWidth = maximumWidth;
                SidebarColumn.Width = new GridLength(
                    Math.Clamp(_sidebarWidth, MinimumSidebarWidth, maximumWidth));
                SidebarPanel.Visibility = Visibility.Visible;
                SidebarSplitter.Visibility = Visibility.Visible;
            }
            else
            {
                SidebarColumn.MinWidth = 0;
                SidebarColumn.Width = new GridLength(0);
                SidebarPanel.Visibility = Visibility.Collapsed;
                SidebarSplitter.Visibility = Visibility.Collapsed;
            }
        }

        private void SidebarSplitter_DragCompleted(object sender, DragCompletedEventArgs e)
        {
            double maximumWidth = EffectiveMaximumSidebarWidth();
            _sidebarWidth = Math.Clamp(
                SidebarColumn.ActualWidth,
                MinimumSidebarWidth,
                maximumWidth);
            SidebarColumn.Width = new GridLength(_sidebarWidth);
            _settings.SidebarWidth = _sidebarWidth;
        }

        private void SidebarSplitter_MouseDoubleClick(object sender, MouseButtonEventArgs e)
        {
            _sidebarWidth = DefaultSidebarWidth;
            SidebarColumn.Width = new GridLength(_sidebarWidth);
            _settings.SidebarWidth = _sidebarWidth;
            e.Handled = true;
        }

        private double EffectiveMaximumSidebarWidth()
        {
            if (GridMode.ActualWidth <= 0) return MaximumSidebarWidth;
            return Math.Clamp(
                GridMode.ActualWidth - MinimumLibraryWidth - SidebarDividerWidth,
                MinimumSidebarWidth,
                MaximumSidebarWidth);
        }

        private void UpdateSidebarWidthForWindow()
        {
            if (!_isSidebarVisible || GridMode.ActualWidth <= 0) return;
            double maximumWidth = EffectiveMaximumSidebarWidth();
            SidebarColumn.MaxWidth = maximumWidth;
            SidebarColumn.Width = new GridLength(
                Math.Clamp(_sidebarWidth, MinimumSidebarWidth, maximumWidth));
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
                    _rotationStore.Remove(photo.FilePath);
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
            bool shift = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;
            bool alt = (Keyboard.Modifiers & ModifierKeys.Alt) != 0;
            if (control && shift && e.Key == Key.N)
            {
                BtnNewFolder_Click(sender, e);
                e.Handled = true;
                return;
            }
            if (control && alt && e.Key == Key.C)
            {
                BtnCollapseAll_Click(sender, e);
                e.Handled = true;
                return;
            }
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

            if (control && e.Key == Key.C)
            {
                CopyActiveResourceSelection();
                e.Handled = true;
                return;
            }
            if (control && e.Key == Key.V)
            {
                _ = PasteCopiedPhotosAsync();
                e.Handled = true;
                return;
            }
            if (control && e.Key == Key.A)
            {
                if (_activeResourceSelectionSurface == ResourceSelectionSurface.DirectoryTree)
                    SelectAllVisibleDirectoryNodes();
                else
                    SelectAllVisiblePhotos();
                e.Handled = true;
                return;
            }

            if (HandleDirectoryTreeKeyboard(e, shift)) return;

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
            SelectPhoto(
                _visiblePhotos[target],
                shift ? ModifierKeys.Shift : ModifierKeys.None);
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
