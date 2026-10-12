import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../domain/models/discovery.dart';
import '../../domain/models/drama.dart';
import '../../domain/models/remote_key_map.dart';
import '../../playback/device_controls.dart';
import '../../playback/media_kit_engine.dart';
import '../../playback/playback_session.dart';
import '../shared/widgets.dart';
import 'tv_focus.dart';
import 'tv_player_screen.dart';

/// TV 遥控刷短剧模式 (TV Feed Screen)。
///
/// 核心场景：找剧、试看选剧。
/// 模式 A 规则：
/// - 【↓ 下键】：切到「下一部短剧」（从第 1 集起播，换台找剧）
/// - 【↑ 上键】：切回「上一部短剧」
/// - 【← / → 左右键】：快退 / 快进（长按连续前进），并显示进度条
/// - 【OK 确定键】：唤出「快速追剧卡」（看全集、看下一集、选集、收藏、暂停）
/// - 【菜单键】：呼出完整选集与画质/倍速面板
/// - 【返回键】：退出刷剧，返回主界面
class TVFeedScreen extends StatefulWidget {
  const TVFeedScreen({
    super.key,
    this.initialDrama,
    this.initialDramas,
  });

  final Drama? initialDrama;
  final List<Drama>? initialDramas;

  @override
  State<TVFeedScreen> createState() => _TVFeedScreenState();
}

class _TVFeedScreenState extends State<TVFeedScreen> with WidgetsBindingObserver {
  late final AppController _app;
  late final MediaKitEngine _engine;
  PlaybackSession? _session;
  late final DeviceControls _device;

  final List<Drama> _feedList = [];
  int _currentIndex = 0;
  bool _loadingFeed = true;
  bool _switchingDrama = false;
  bool _infoVisible = true;
  bool _quickActionsOpen = false;
  bool _sheetOpen = false;
  bool _foreground = true;
  bool _awake = false;
  bool _closing = false;

  Timer? _hideInfoTimer;
  Timer? _seekDebounce;
  Duration? _seekPreview;
  String? _toastMessage;
  Timer? _toastTimer;
  double _verticalDragDistance = 0.0;
  double _horizontalDragDistance = 0.0;

  Drama? get _currentDrama =>
      (_feedList.isNotEmpty && _currentIndex >= 0 && _currentIndex < _feedList.length)
          ? _feedList[_currentIndex]
          : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app = AppScope.read(context);
    _engine = MediaKitEngine(preferences: _app.preferences);
    _device = DeviceControls(_engine);

    tvPlayerDebugActions = TVPlayerDebugActions(
      onUp: _previousDrama,
      onDown: _nextDrama,
      onLeft: () => _seekBy(Duration(seconds: -_app.preferences.seekStepSeconds)),
      onRight: () => _seekBy(Duration(seconds: _app.preferences.seekStepSeconds)),
      onOk: _handleOkPress,
    );

    unawaited(_prepareDevice());
    unawaited(_initFeedData());
  }

  Future<void> _prepareDevice() async {
    if (Platform.isAndroid) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      if (!mounted || _closing) return;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    await _device.initialize();
  }

  Future<void> _initFeedData() async {
    final list = <Drama>[];
    if (widget.initialDramas != null && widget.initialDramas!.isNotEmpty) {
      list.addAll(widget.initialDramas!);
    } else {
      // 优先加载热播榜
      try {
        final hotPage = await _app.repository.getRanking(RankingType.hot);
        for (final item in hotPage.items) {
          if (!list.any((d) => d.id == item.drama.id)) {
            list.add(item.drama);
          }
        }
      } catch (_) {}

      // 补充剧库本地/已缓存剧目
      final catalog = _app.repository.catalog;
      for (final d in catalog) {
        if (!list.any((item) => item.id == d.id)) {
          list.add(d);
        }
      }
    }

    if (!mounted || _closing) return;

    if (list.isEmpty) {
      // 若仍为空，尝试刷新仓库
      try {
        await _app.repository.refresh();
        list.addAll(_app.repository.catalog);
      } catch (_) {}
    }

    if (!mounted || _closing) return;

    setState(() {
      _feedList.clear();
      _feedList.addAll(list);
      _loadingFeed = false;
      if (widget.initialDrama != null) {
        final found = _feedList.indexWhere((d) => d.id == widget.initialDrama!.id);
        if (found >= 0) {
          _currentIndex = found;
        } else {
          _feedList.insert(0, widget.initialDrama!);
          _currentIndex = 0;
        }
      }
    });

    if (_feedList.isNotEmpty) {
      _startPlayCurrentDrama();
    }
  }

  void _startPlayCurrentDrama() {
    final drama = _currentDrama;
    if (drama == null) return;

    if (_session == null) {
      _session = PlaybackSession(
        app: _app,
        engine: _engine,
        drama: drama,
      );
      _session!.addListener(_onSessionUpdate);
      unawaited(_session!.initialize(initialEpisode: 1));
    } else {
      unawaited(_session!.switchDrama(drama, initialEpisode: 1));
    }

    _showInfoTemporarily('正在换台: 《${drama.title}》');
    _preloadNextDrama();
  }

  void _preloadNextDrama() {
    final nextIndex = _currentIndex + 1;
    if (nextIndex < _feedList.length) {
      // 静默拉取下一部剧的详情，提前写入本地缓存
      unawaited(_app.repository.getDetail(_feedList[nextIndex]));
    }
    // 列表快见底时自动拉取更多
    if (_currentIndex >= _feedList.length - 4) {
      unawaited(_loadMoreDramas());
    }
  }

  Future<void> _loadMoreDramas() async {
    try {
      await _app.repository.loadMore();
      if (!mounted || _closing) return;
      final catalog = _app.repository.catalog;
      var added = 0;
      for (final d in catalog) {
        if (!_feedList.any((item) => item.id == d.id)) {
          _feedList.add(d);
          added++;
        }
      }
      if (added > 0 && mounted) {
        setState(() {});
      }
    } catch (_) {}
  }

  void _onSessionUpdate() {
    if (!mounted || _closing) return;
    final awake = _foreground &&
        (_session?.playing == true || _session?.buffering == true) &&
        !_sheetOpen;
    if (awake != _awake) {
      _awake = awake;
      unawaited(_device.keepAwake(awake));
    }
    setState(() {});
  }

  void _showInfoTemporarily([String? toast]) {
    if (toast != null) {
      _showToast(toast);
    }
    setState(() => _infoVisible = true);
    _hideInfoTimer?.cancel();
    _hideInfoTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_closing && !_quickActionsOpen && !_sheetOpen) {
        setState(() => _infoVisible = false);
      }
    });
  }

  void _showToast(String message) {
    _toastMessage = message;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_closing) {
        setState(() => _toastMessage = null);
      }
    });
  }

  /// 换下一部剧 (方式 A：始终切下一部剧第 1 集)
  void _nextDrama() {
    if (_switchingDrama || _sheetOpen) return;
    if (_feedList.isEmpty) return;

    if (_currentIndex + 1 >= _feedList.length) {
      _showToast('正在探索更多新剧...');
      unawaited(_loadMoreDramas());
      return;
    }

    _switchingDrama = true;
    _currentIndex++;
    _quickActionsOpen = false;
    setState(() {});
    _startPlayCurrentDrama();
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _switchingDrama = false;
    });
  }

  /// 换上一部剧
  void _previousDrama() {
    if (_switchingDrama || _sheetOpen) return;
    if (_feedList.isEmpty) return;

    if (_currentIndex <= 0) {
      _showToast('已经是第一部短剧了');
      return;
    }

    _switchingDrama = true;
    _currentIndex--;
    _quickActionsOpen = false;
    setState(() {});
    _startPlayCurrentDrama();
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _switchingDrama = false;
    });
  }

  /// 遥控器快进/快退
  void _seekBy(Duration delta) {
    if (_session == null || _session!.duration == Duration.zero) return;
    final current = _seekPreview ?? _session!.position;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _session!.duration) target = _session!.duration;

    _seekPreview = target;
    _showInfoTemporarily();

    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 600), () {
      if (_seekPreview != null && mounted && _session != null) {
        unawaited(_session!.seek(_seekPreview!));
        _seekPreview = null;
        setState(() {});
      }
    });
  }

  /// 看当前剧的下一集
  void _playNextEpisodeOfCurrentDrama() {
    if (_session == null) return;
    if (!_session!.canNext) {
      _showToast('当前剧已经没有下一集了');
      return;
    }
    unawaited(_session!.next());
    _quickActionsOpen = false;
    _showInfoTemporarily('播放下一集: 第 ${_session!.currentIndex + 2} 集');
  }

  /// 展开完整播放器（深入追剧）
  Future<void> _enterFullPlayer() async {
    final drama = _currentDrama;
    if (drama == null || _session == null) return;
    final currentEp = _session!.episode?.index ?? 1;

    // 暂停当前刷剧流
    _session!.hold('full_player');
    try {
      _engine.player.pause();
    } catch (_) {}

    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => TVPlayerScreen(
          drama: drama,
          initialEpisode: currentEp,
        ),
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: animation,
          child: child,
        ),
      ),
    );

    if (mounted && !_closing) {
      _session!.release('full_player');
      _startPlayCurrentDrama();
    }
  }

  void _handleOkPress() {
    if (_sheetOpen) return;
    if (!_quickActionsOpen) {
      setState(() {
        _quickActionsOpen = true;
        _infoVisible = true;
      });
      _hideInfoTimer?.cancel();
    } else {
      // 默认切换播放/暂停
      _session?.togglePlay();
      _showInfoTemporarily();
    }
  }

  Future<void> _openEpisodes() async {
    if (_session == null || _currentDrama == null) return;
    _session!.hold('sheet');
    setState(() => _sheetOpen = true);
    try {
      final result = await showReelSheet<Episode>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '选集 · ${_currentDrama!.title}',
          subtitle: '共 ${_session!.episodes.length} 集',
          child: _EpisodeGrid(
            episodes: _session!.episodes,
            current: _session!.episode?.index,
            onSelect: (episode) => Navigator.of(context).pop(episode),
          ),
        ),
      );
      if (result != null) {
        final index = _session!.episodes.indexOf(result);
        unawaited(_session!.playEpisode(index));
        _quickActionsOpen = false;
      }
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session!.release('sheet');
        _showInfoTemporarily();
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_sheetOpen) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyMap = _app.remoteKeyMap;
    final step = Duration(seconds: _app.preferences.seekStepSeconds);

    // 返回键
    if (keyMap.matches(RemoteAction.back, key)) {
      if (_quickActionsOpen) {
        setState(() => _quickActionsOpen = false);
        _showInfoTemporarily();
        return KeyEventResult.handled;
      }
      _exit();
      return KeyEventResult.handled;
    }

    // 菜单键
    if (keyMap.matches(RemoteAction.menu, key)) {
      unawaited(_openEpisodes());
      return KeyEventResult.handled;
    }

    // OK / 确认键
    if (keyMap.matches(RemoteAction.ok, key)) {
      _handleOkPress();
      return KeyEventResult.handled;
    }

    // 方向【下】：换下一部剧
    if (keyMap.matches(RemoteAction.down, key)) {
      _nextDrama();
      return KeyEventResult.handled;
    }

    // 方向【上】：换上一部剧
    if (keyMap.matches(RemoteAction.up, key)) {
      _previousDrama();
      return KeyEventResult.handled;
    }

    // 方向【左】：快退
    if (keyMap.matches(RemoteAction.left, key)) {
      _seekBy(-step);
      return KeyEventResult.handled;
    }

    // 方向【右】：快进
    if (keyMap.matches(RemoteAction.right, key)) {
      _seekBy(step);
      return KeyEventResult.handled;
    }

    // 媒体按键
    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _session?.togglePlay();
      _showInfoTemporarily();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _cleanup() {
    if (_closing) return;
    _closing = true;
    try {
      _engine.player.pause();
      _engine.player.stop();
    } catch (_) {}
    _session?.saveProgress();
    _session?.close();
  }

  void _exit() {
    _cleanup();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _cleanup();
    tvPlayerDebugActions = null;
    WidgetsBinding.instance.removeObserver(this);
    _hideInfoTimer?.cancel();
    _seekDebounce?.cancel();
    _toastTimer?.cancel();
    _session?.removeListener(_onSessionUpdate);
    unawaited(_device.dispose());
    if (Platform.isAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      unawaited(SystemChrome.setPreferredOrientations([]));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final drama = _currentDrama;
    final session = _session;

    return Theme(
      data: ReelTheme.make(Brightness.dark, _app.preferences.accentColorKey),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            if (_quickActionsOpen) {
              setState(() => _quickActionsOpen = false);
              return;
            }
            _exit();
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Focus(
            autofocus: true,
            onKeyEvent: _onKey,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 弥散模糊背景（当播放竖屏视频时，让 16:9 大屏充满氛围感）
                if (drama != null)
                  Positioned.fill(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CoverImage(
                          drama: drama,
                          fit: BoxFit.cover,
                        ),
                        BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
                          child: Container(
                            color: Colors.black.withValues(alpha: .72),
                          ),
                        ),
                      ],
                    ),
                  ),

                // 2. 视频画面
                Center(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _engine.videoChanges,
                    builder: (context, _, _) {
                      final controller = _engine.video;
                      return Video(
                        key: ObjectKey(controller),
                        controller: controller,
                        fit: BoxFit.contain,
                        controls: NoVideoControls,
                        pauseUponEnteringBackgroundMode: false,
                        resumeUponEnteringForegroundMode: false,
                        wakelock: false,
                      );
                    },
                  ),
                ),

                // 3. 点击画面呼出操作 & 触控上下滑动切剧 / 左右滑动快进退
                Positioned.fill(
                  child: Listener(
                    onPointerSignal: (pointerSignal) {
                      if (pointerSignal is PointerScrollEvent) {
                        if (pointerSignal.scrollDelta.dy > 20) {
                          _nextDrama();
                        } else if (pointerSignal.scrollDelta.dy < -20) {
                          _previousDrama();
                        }
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _handleOkPress,
                      onVerticalDragStart: (_) {
                        _verticalDragDistance = 0.0;
                      },
                      onVerticalDragUpdate: (details) {
                        _verticalDragDistance += details.delta.dy;
                      },
                      onVerticalDragEnd: (details) {
                        final velocity = details.primaryVelocity ?? 0.0;
                        // 向上滑动（手指向上划，delta < 0 或速度 < 0）-> 下一部剧（Next Drama）
                        if (velocity < -200 || _verticalDragDistance < -60) {
                          if (_quickActionsOpen) {
                            setState(() => _quickActionsOpen = false);
                          }
                          _nextDrama();
                        }
                        // 向下滑动（手指向下划，delta > 0 或速度 > 0）-> 上一部剧（Previous Drama）
                        else if (velocity > 200 || _verticalDragDistance > 60) {
                          if (_quickActionsOpen) {
                            setState(() => _quickActionsOpen = false);
                          }
                          _previousDrama();
                        }
                        _verticalDragDistance = 0.0;
                      },
                      onHorizontalDragStart: (_) {
                        _horizontalDragDistance = 0.0;
                      },
                      onHorizontalDragUpdate: (details) {
                        _horizontalDragDistance += details.delta.dx;
                      },
                      onHorizontalDragEnd: (details) {
                        final velocity = details.primaryVelocity ?? 0.0;
                        final step = Duration(seconds: _app.preferences.seekStepSeconds);
                        // 向右滑动：快进
                        if (velocity > 250 || _horizontalDragDistance > 60) {
                          _seekBy(step);
                        }
                        // 向左滑动：快退
                        else if (velocity < -250 || _horizontalDragDistance < -60) {
                          _seekBy(-step);
                        }
                        _horizontalDragDistance = 0.0;
                      },
                    ),
                  ),
                ),

                // 4. 加载中指示器
                if (_loadingFeed || session?.buffering == true || _switchingDrama)
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .6),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            ),
                            const SizedBox(width: 14),
                            Text(
                              _switchingDrama
                                  ? '正在换台...'
                                  : (session?.loadingMessage ?? '正在加载短剧...'),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // 5. 快进/快退进度条条
                if (_seekPreview != null && session != null)
                  Positioned(
                    top: 48,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .78),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white24, width: .8),
                          ),
                          child: Text(
                            '${_formatDuration(_seekPreview!)} / ${_formatDuration(session.duration)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // 6. 顶部换台状态轻提示
                if (_toastMessage != null)
                  Positioned(
                    top: 36,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: _toastMessage != null ? 1.0 : 0.0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                            decoration: BoxDecoration(
                              color: context.colors.primary.withValues(alpha: .9),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: .4),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: Text(
                              _toastMessage!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // 7. 剧名与剧集信息（左下角浮层）
                if (drama != null)
                  Positioned(
                    left: 36,
                    bottom: 32,
                    right: 36,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 320),
                      opacity: _infoVisible ? 1.0 : 0.15,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 剧名与热度/集数
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                drama.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 26,
                                  fontWeight: FontWeight.w800,
                                  shadows: [
                                    Shadow(color: Colors.black87, blurRadius: 10),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 14),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: context.colors.primary.withValues(alpha: .85),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '第 ${session?.episode?.index ?? 1} 集 / 共 ${drama.episodeCount} 集',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (drama.tags.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Text(
                                  drama.tags.take(3).map((t) => '#$t').join(' '),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    shadows: [
                                      Shadow(color: Colors.black, blurRadius: 8),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),

                          // 简介（两行）
                          if (drama.intro.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 620),
                              child: Text(
                                drama.intro,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  height: 1.45,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 8),
                                  ],
                                ),
                              ),
                            ),
                          ],

                          const SizedBox(height: 14),

                          // 快速操作栏（当按 OK 呼出时）
                          if (_quickActionsOpen) ...[
                            _buildQuickActionButtons(context, drama),
                            const SizedBox(height: 12),
                          ],

                          // 遥控器按键指南
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .5),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white12, width: .8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _keyPill('↓ / 上滑', '换下一部'),
                                const SizedBox(width: 12),
                                _keyPill('↑ / 下滑', '换上一部'),
                                const SizedBox(width: 12),
                                _keyPill('←/→ / 滑动', '快退/快进'),
                                const SizedBox(width: 12),
                                _keyPill('OK / 轻触', _quickActionsOpen ? '暂停/播放' : '追剧操作卡'),
                                const SizedBox(width: 12),
                                _keyPill('菜单', '选集'),
                                const SizedBox(width: 12),
                                _keyPill('返回', '退出刷剧'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 8. 正在暂停大图标（若已暂停）
                if (session != null && !session.playing && !session.buffering)
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 46,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActionButtons(BuildContext context, Drama drama) {
    final isFav = _app.isFavorite(drama.id);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _quickButton(
          icon: Icons.movie_rounded,
          label: '完整追剧',
          highlight: true,
          onTap: _enterFullPlayer,
        ),
        const SizedBox(width: 10),
        _quickButton(
          icon: Icons.skip_next_rounded,
          label: '看下一集',
          onTap: _playNextEpisodeOfCurrentDrama,
        ),
        const SizedBox(width: 10),
        _quickButton(
          icon: Icons.grid_view_rounded,
          label: '选集',
          onTap: _openEpisodes,
        ),
        const SizedBox(width: 10),
        _quickButton(
          icon: isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          label: isFav ? '已收藏' : '收藏',
          onTap: () {
            _app.toggleFavorite(drama);
            setState(() {});
          },
        ),
        const SizedBox(width: 10),
        _quickButton(
          icon: (_session?.playing == true) ? Icons.pause_rounded : Icons.play_arrow_rounded,
          label: (_session?.playing == true) ? '暂停' : '播放',
          onTap: () => _session?.togglePlay(),
        ),
      ],
    );
  }

  Widget _quickButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlight = false,
  }) => TVFocusable(
    radius: 10,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: highlight
            ? Theme.of(context).colorScheme.primary
            : Colors.white.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: highlight ? Colors.transparent : Colors.white24,
          width: .8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: highlight ? Colors.white : Colors.white70,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: highlight ? Colors.white : Colors.white70,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _keyPill(String key, String desc) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          key,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      const SizedBox(width: 5),
      Text(
        desc,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
        ),
      ),
    ],
  );

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// TV 选集网格弹层
class _EpisodeGrid extends StatelessWidget {
  const _EpisodeGrid({
    required this.episodes,
    required this.current,
    required this.onSelect,
  });

  final List<Episode> episodes;
  final int? current;
  final ValueChanged<Episode> onSelect;

  @override
  Widget build(BuildContext context) {
    if (episodes.isEmpty) {
      return const Center(child: Text('暂无分集信息', style: TextStyle(color: Colors.white54)));
    }
    return SizedBox(
      height: 320,
      child: SingleChildScrollView(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = (constraints.maxWidth / 80).floor().clamp(4, 10);
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final ep in episodes)
                  SizedBox(
                    width: (constraints.maxWidth - (columns - 1) * 8) / columns,
                    child: TVFocusable(
                      radius: 10,
                      autofocus: ep.index == current,
                      onTap: () => onSelect(ep),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: ep.index == current
                              ? context.colors.primary
                              : Colors.white.withValues(alpha: .06),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${ep.index}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: ep.index == current
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: ep.index == current
                                ? Colors.white
                                : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
