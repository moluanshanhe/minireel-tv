import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../domain/models/remote_key_map.dart';
import '../shared/widgets.dart';
import 'tv_focus.dart';

/// 遥控器映射设置入口：展示全部动作的绑定，支持单键自定义、全局向导学习与实时按键检测。
Future<void> showRemoteKeySettings(BuildContext context) async {
  final app = AppScope.read(context);
  await showReelSheet<void>(
    context,
    dark: true,
    builder: (context) => _RemoteKeySettingsSheet(app: app),
  );
}

class _RemoteKeySettingsSheet extends StatefulWidget {
  const _RemoteKeySettingsSheet({required this.app});
  final AppController app;

  @override
  State<_RemoteKeySettingsSheet> createState() =>
      _RemoteKeySettingsSheetState();
}

class _RemoteKeySettingsSheetState extends State<_RemoteKeySettingsSheet> {
  late RemoteKeyMap _map;

  @override
  void initState() {
    super.initState();
    _map = widget.app.remoteKeyMap;
  }

  void _save(RemoteKeyMap next) {
    _map = next;
    widget.app.setPreferences(
      widget.app.preferences.copyWith(remoteKeyMap: next),
    );
    setState(() {});
  }

  Future<void> _customizeAction(RemoteAction action) async {
    final result = await showDialog<RemoteKeyMap>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _SingleKeyLearningDialog(
        action: action,
        currentMap: _map,
      ),
    );
    if (result != null && mounted) {
      _save(result);
    }
  }

  Future<void> _startFullLearning() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const RemoteKeyLearningSheet(),
    );
    if (result == true && mounted) {
      setState(() => _map = widget.app.remoteKeyMap);
    }
  }

  Future<void> _startKeyTester() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _RemoteKeyTesterDialog(map: _map),
    );
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认映射'),
        content: const Text('将清除所有自定义按键绑定，恢复出厂默认遥控器设置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _save(RemoteKeyMap.reset());
    }
  }

  Future<void> _clearAction(RemoteAction action) async {
    _save(_map.clearAction(action));
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.colors.primary;
    final navActions = RemoteAction.values.where((a) => a.isNavigation).toList();
    final mediaActions =
        RemoteAction.values.where((a) => !a.isNavigation).toList();

    return SheetFrame(
      title: '遥控器按键自定义',
      subtitle: '点击任意动作即可为该功能单独录制或追加遥控器按键',
      footer: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Expanded(
              child: TVFocusable(
                radius: 12,
                onTap: _startKeyTester,
                child: FilledButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.speed_rounded, size: 19),
                  label: const Text('按键检测测试'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TVFocusable(
                radius: 12,
                onTap: _startFullLearning,
                child: OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.school_rounded, size: 19),
                  label: const Text('全部向导学习'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TVFocusable(
              radius: 12,
              onTap: _reset,
              child: OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.restart_alt_rounded, size: 19),
                label: const Text('恢复默认'),
              ),
            ),
          ],
        ),
      ),
      child: FocusTraversalGroup(
        policy: TVFocusTraversalPolicy(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 分组1：基础导航与核心操作
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Text(
                '基础导航键',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: context.muted,
                ),
              ),
            ),
            for (final action in navActions) ...[
              _actionCard(context, action, accent),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 12),
            // 分组2：独立播放与扩展快捷键
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
              child: Text(
                '独立播放控制键（可选·适合带多媒体/频道键的遥控器）',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: context.muted,
                ),
              ),
            ),
            for (final action in mediaActions) ...[
              _actionCard(context, action, accent),
              const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actionCard(
    BuildContext context,
    RemoteAction action,
    Color accent,
  ) {
    final count = _map.countOf(action);
    return TVFocusable(
      radius: 12,
      onTap: () => _customizeAction(action),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_iconFor(action), size: 18, color: accent),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 80,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    action.label,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    action.hint,
                    style: TextStyle(fontSize: 11, color: context.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: count == 0
                  ? Text(
                      '未设置（点击录制）',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white38,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  : Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final keyId in _map.keyIdsOf(action))
                          _keyBadge(RemoteKeyMap.keyNameById(keyId), accent),
                      ],
                    ),
            ),
            const SizedBox(width: 8),
            if (count > 0)
              TVFocusable(
                radius: 6,
                onTap: () => _clearAction(action),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 17,
                    color: Colors.white38,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 20, color: Colors.white30),
          ],
        ),
      ),
    );
  }

  Widget _keyBadge(String label, Color accent) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white12),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Colors.white70,
          ),
        ),
      );

  IconData _iconFor(RemoteAction action) => switch (action) {
        RemoteAction.up => Icons.arrow_upward_rounded,
        RemoteAction.down => Icons.arrow_downward_rounded,
        RemoteAction.left => Icons.arrow_back_rounded,
        RemoteAction.right => Icons.arrow_forward_rounded,
        RemoteAction.ok => Icons.adjust_rounded,
        RemoteAction.back => Icons.undo_rounded,
        RemoteAction.menu => Icons.menu_rounded,
        RemoteAction.playPause => Icons.play_arrow_rounded,
        RemoteAction.fastForward => Icons.fast_forward_rounded,
        RemoteAction.rewind => Icons.fast_rewind_rounded,
        RemoteAction.nextEpisode => Icons.skip_next_rounded,
        RemoteAction.prevEpisode => Icons.skip_previous_rounded,
      };
}

/// 单个动作的专属按键录制学习弹窗。
class _SingleKeyLearningDialog extends StatefulWidget {
  const _SingleKeyLearningDialog({
    required this.action,
    required this.currentMap,
  });

  final RemoteAction action;
  final RemoteKeyMap currentMap;

  @override
  State<_SingleKeyLearningDialog> createState() =>
      _SingleKeyLearningDialogState();
}

class _SingleKeyLearningDialogState extends State<_SingleKeyLearningDialog> {
  int? _capturedKeyId;
  String? _capturedKeyName;
  RemoteAction? _conflictingAction;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // 忽略修饰键
    if (key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.meta) {
      return KeyEventResult.ignored;
    }

    final keyId = key.keyId;
    final name = RemoteKeyMap.keyName(key);
    final conflict = widget.currentMap.findActionForKey(key);

    setState(() {
      _capturedKeyId = keyId;
      _capturedKeyName = name;
      _conflictingAction = conflict == widget.action ? null : conflict;
    });

    return KeyEventResult.handled;
  }

  void _applyReplace() {
    if (_capturedKeyId == null) return;
    final next = widget.currentMap.setKey(widget.action, _capturedKeyId!);
    Navigator.of(context).pop(next);
  }

  void _applyAppend() {
    if (_capturedKeyId == null) return;
    final next = widget.currentMap.addKey(widget.action, _capturedKeyId!);
    Navigator.of(context).pop(next);
  }

  void _applyClear() {
    final next = widget.currentMap.clearAction(widget.action);
    Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.colors.primary;
    return Dialog(
      backgroundColor: const Color(0xFF171A22),
      constraints: const BoxConstraints(maxWidth: 480),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Theme(
        data: ReelTheme.make(Brightness.dark),
        child: Focus(
          onKeyEvent: _onKey,
          autofocus: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '录制按键 · ${widget.action.label}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                // 监听状态指示器
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  decoration: BoxDecoration(
                    color: _capturedKeyId != null
                        ? accent.withValues(alpha: .12)
                        : Colors.white.withValues(alpha: .04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _capturedKeyId != null ? accent : Colors.white12,
                      width: 1.5,
                    ),
                  ),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          _capturedKeyId != null
                              ? Icons.check_circle_rounded
                              : Icons.settings_remote_rounded,
                          size: 44,
                          color: _capturedKeyId != null ? accent : Colors.white60,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _capturedKeyId != null
                              ? '已捕获按键：$_capturedKeyName'
                              : '请按下遥控器上的任意按键...',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _capturedKeyId != null ? accent : Colors.white,
                          ),
                        ),
                        if (_capturedKeyId != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'KeyID: 0x${_capturedKeyId!.toRadixString(16)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                        if (_conflictingAction != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            '⚠️ 该按键当前已绑定到【${_conflictingAction!.label}】',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.amber,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                if (_capturedKeyId != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: TVFocusable(
                          radius: 10,
                          onTap: _applyReplace,
                          child: FilledButton(
                            onPressed: null,
                            child: const Text('覆盖旧按键'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TVFocusable(
                          radius: 10,
                          onTap: _applyAppend,
                          child: OutlinedButton(
                            onPressed: null,
                            child: const Text('追加保留旧键'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: _applyClear,
                      child: const Text(
                        '清空此动作按键',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 遥控器实时按键检测与冲突排查工具。
class _RemoteKeyTesterDialog extends StatefulWidget {
  const _RemoteKeyTesterDialog({required this.map});
  final RemoteKeyMap map;

  @override
  State<_RemoteKeyTesterDialog> createState() => _RemoteKeyTesterDialogState();
}

class _RemoteKeyTesterDialogState extends State<_RemoteKeyTesterDialog> {
  String? _lastKeyName;
  int? _lastKeyId;
  RemoteAction? _mappedAction;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyId = key.keyId;
    final name = RemoteKeyMap.keyName(key);
    final mapped = widget.map.findActionForKey(key);

    setState(() {
      _lastKeyName = name;
      _lastKeyId = keyId;
      _mappedAction = mapped;
    });

    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.colors.primary;
    return Dialog(
      backgroundColor: const Color(0xFF171A22),
      constraints: const BoxConstraints(maxWidth: 500),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Theme(
        data: ReelTheme.make(Brightness.dark),
        child: Focus(
          onKeyEvent: _onKey,
          autofocus: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.speed_rounded, size: 22, color: Colors.white70),
                    const SizedBox(width: 10),
                    const Text(
                      '遥控器实时按键测试',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text(
                  '请随意按下遥控器上的任意按键，屏幕将实时显示其键码与当前绑定的动作：',
                  style: TextStyle(fontSize: 13, color: Colors.white60),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _lastKeyId != null ? accent : Colors.white12,
                      width: 1.5,
                    ),
                  ),
                  child: Center(
                    child: _lastKeyId == null
                        ? const Column(
                            children: [
                              Icon(Icons.touch_app_rounded,
                                  size: 40, color: Colors.white30),
                              SizedBox(height: 10),
                              Text(
                                '等待按下按键...',
                                style: TextStyle(
                                    fontSize: 15, color: Colors.white54),
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              Text(
                                _lastKeyName ?? '未知按键',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '键码 ID: 0x${_lastKeyId!.toRadixString(16)} (十进制: $_lastKeyId)',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.white54,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _mappedAction != null
                                      ? Colors.green.withValues(alpha: .18)
                                      : Colors.amber.withValues(alpha: .18),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: _mappedAction != null
                                        ? Colors.green
                                        : Colors.amber,
                                  ),
                                ),
                                child: Text(
                                  _mappedAction != null
                                      ? '触发动作：【${_mappedAction!.label}】(${_mappedAction!.hint})'
                                      : '当前未绑定任何动作',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: _mappedAction != null
                                        ? Colors.greenAccent
                                        : Colors.amberAccent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 20),
                Center(
                  child: TVFocusable(
                    radius: 10,
                    onTap: () => Navigator.of(context).pop(),
                    child: FilledButton(
                      onPressed: null,
                      child: const Text('退出测试'),
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
}

/// 遥控器按键向导学习页：逐个引导用户为常用动作绑定物理按键。
class RemoteKeyLearningSheet extends StatefulWidget {
  const RemoteKeyLearningSheet({super.key});
  @override
  State<RemoteKeyLearningSheet> createState() => _RemoteKeyLearningSheetState();
}

class _RemoteKeyLearningSheetState extends State<RemoteKeyLearningSheet> {
  static const _order = [
    RemoteAction.up,
    RemoteAction.down,
    RemoteAction.left,
    RemoteAction.right,
    RemoteAction.ok,
    RemoteAction.back,
    RemoteAction.menu,
    RemoteAction.playPause,
    RemoteAction.fastForward,
    RemoteAction.rewind,
    RemoteAction.nextEpisode,
    RemoteAction.prevEpisode,
  ];

  int _index = 0;
  late RemoteKeyMap _map;
  final Map<RemoteAction, List<int>> _captured = {};

  @override
  void initState() {
    super.initState();
    _map = AppScope.read(context).remoteKeyMap;
  }

  RemoteAction get _current => _order[_index];
  bool get _isLast => _index >= _order.length - 1;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.meta) {
      return KeyEventResult.ignored;
    }

    final keyId = key.keyId;
    setState(() {
      final list = _captured.putIfAbsent(_current, () => []);
      if (!list.contains(keyId)) list.add(keyId);
      _map = _map.addKey(_current, keyId);
    });

    Future.delayed(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      if (_isLast) {
        _finish();
      } else {
        setState(() => _index++);
      }
    });
    return KeyEventResult.handled;
  }

  void _finish() {
    final app = AppScope.read(context);
    app.setPreferences(app.preferences.copyWith(remoteKeyMap: _map));
    Navigator.of(context).pop(true);
  }

  void _skip() {
    if (_isLast) {
      _finish();
    } else {
      setState(() => _index++);
    }
  }

  void _cancel() {
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.colors.primary;
    final captured = _captured[_current] ?? const <int>[];
    return Dialog(
      backgroundColor: const Color(0xFF171A22),
      constraints: const BoxConstraints(maxWidth: 520),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Theme(
        data: ReelTheme.make(Brightness.dark),
        child: Focus(
          onKeyEvent: _onKey,
          autofocus: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Text(
                      '遥控器按键向导学习',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_index + 1} / ${_order.length}',
                      style: TextStyle(
                        fontSize: 13,
                        color: context.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: (_index + (captured.isNotEmpty ? 0.5 : 0)) /
                        _order.length,
                    minHeight: 4,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation(accent),
                  ),
                ),
                const SizedBox(height: 28),
                Center(
                  child: Column(
                    children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accent.withValues(alpha: .12),
                          border: Border.all(color: accent, width: 2),
                        ),
                        child: Icon(
                          _iconFor(_current),
                          size: 40,
                          color: accent,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '请按下遥控器上的',
                        style: TextStyle(fontSize: 15, color: Colors.white70),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '「${_current.hint}」',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: accent,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                if (captured.isNotEmpty)
                  Center(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final keyId in captured)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: .15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: accent.withValues(alpha: .4)),
                            ),
                            child: Text(
                              RemoteKeyMap.keyNameById(keyId),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: accent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  )
                else
                  Center(
                    child: Text(
                      '按键后将自动记录并进入下一个（无需该功能可直接跳过）',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.muted,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: _cancel,
                      child: const Text('取消'),
                    ),
                    TVFocusable(
                      radius: 10,
                      onTap: _skip,
                      child: FilledButton.icon(
                        onPressed: null,
                        icon: Icon(
                          _isLast
                              ? Icons.check_rounded
                              : Icons.skip_next_rounded,
                          size: 18,
                        ),
                        label: Text(_isLast ? '完成' : '跳过此项'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(RemoteAction action) => switch (action) {
        RemoteAction.up => Icons.arrow_upward_rounded,
        RemoteAction.down => Icons.arrow_downward_rounded,
        RemoteAction.left => Icons.arrow_back_rounded,
        RemoteAction.right => Icons.arrow_forward_rounded,
        RemoteAction.ok => Icons.adjust_rounded,
        RemoteAction.back => Icons.undo_rounded,
        RemoteAction.menu => Icons.menu_rounded,
        RemoteAction.playPause => Icons.play_arrow_rounded,
        RemoteAction.fastForward => Icons.fast_forward_rounded,
        RemoteAction.rewind => Icons.fast_rewind_rounded,
        RemoteAction.nextEpisode => Icons.skip_next_rounded,
        RemoteAction.prevEpisode => Icons.skip_previous_rounded,
      };
}
