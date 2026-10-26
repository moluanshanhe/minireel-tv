import 'package:flutter/services.dart';

/// 遥控器逻辑动作。
///
/// 包含核心导航动作与专用播放控制动作，物理按键到动作的映射
/// 由 [RemoteKeyMap] 配置，可在设置页由用户重新学习绑定，
/// 解决不同品牌电视、盒子遥控器键码不一致的问题。
enum RemoteAction {
  up,
  down,
  left,
  right,
  ok,
  back,
  menu,
  playPause,
  fastForward,
  rewind,
  nextEpisode,
  prevEpisode;

  /// 用户可见的动作名称。
  String get label => switch (this) {
        RemoteAction.up => '上',
        RemoteAction.down => '下',
        RemoteAction.left => '左',
        RemoteAction.right => '右',
        RemoteAction.ok => '确认',
        RemoteAction.back => '返回',
        RemoteAction.menu => '菜单',
        RemoteAction.playPause => '播放/暂停',
        RemoteAction.fastForward => '快进',
        RemoteAction.rewind => '快退',
        RemoteAction.nextEpisode => '下一集',
        RemoteAction.prevEpisode => '上一集',
      };

  /// 动作说明（设置与学习页提示用）。
  String get hint => switch (this) {
        RemoteAction.up => '方向键上',
        RemoteAction.down => '方向键下',
        RemoteAction.left => '方向键左 / 快退',
        RemoteAction.right => '方向键右 / 快进',
        RemoteAction.ok => '中间 OK 键 / 播放暂停',
        RemoteAction.back => '返回键 / 退出',
        RemoteAction.menu => '三条横杠键（菜单键）',
        RemoteAction.playPause => '独立播放/暂停键',
        RemoteAction.fastForward => '独立快进按键',
        RemoteAction.rewind => '独立快退按键',
        RemoteAction.nextEpisode => '频道+ 或 下一曲按键',
        RemoteAction.prevEpisode => '频道- 或 上一曲按键',
      };

  /// 是否属于基础导航动作（默认展示在第一组）。
  bool get isNavigation => switch (this) {
        RemoteAction.up ||
        RemoteAction.down ||
        RemoteAction.left ||
        RemoteAction.right ||
        RemoteAction.ok ||
        RemoteAction.back ||
        RemoteAction.menu =>
          true,
        _ => false,
      };
}

/// 遥控器按键映射：[RemoteAction] → 一组 [LogicalKeyboardKey]。
///
/// 一个动作可绑定多个物理键（兼容不同遥控器 + 键盘）。
/// 默认映射覆盖常见遥控器与 Android TV 标准键码。
/// 通过 [Preferences] 持久化，用户可在设置页自由自定义。
final class RemoteKeyMap {
  const RemoteKeyMap(this._bindings);

  /// action → keyId 集合。存 keyId（int）而非 LogicalKeyboardKey，
  /// 因为 keyId 是跨平台稳定的 32/64 位唯一标识。
  final Map<RemoteAction, Set<int>> _bindings;

  /// 默认映射：覆盖 Android TV 标准键 + 常见遥控器变体 + 媒体键 + 键盘。
  factory RemoteKeyMap.defaults() => RemoteKeyMap({
        RemoteAction.up: {
          LogicalKeyboardKey.arrowUp.keyId,
        },
        RemoteAction.down: {
          LogicalKeyboardKey.arrowDown.keyId,
        },
        RemoteAction.left: {
          LogicalKeyboardKey.arrowLeft.keyId,
        },
        RemoteAction.right: {
          LogicalKeyboardKey.arrowRight.keyId,
        },
        RemoteAction.ok: {
          LogicalKeyboardKey.select.keyId,
          LogicalKeyboardKey.enter.keyId,
          LogicalKeyboardKey.gameButtonA.keyId,
          LogicalKeyboardKey.space.keyId,
        },
        RemoteAction.back: {
          LogicalKeyboardKey.escape.keyId,
          LogicalKeyboardKey.goBack.keyId,
        },
        RemoteAction.menu: {
          LogicalKeyboardKey.contextMenu.keyId,
          LogicalKeyboardKey.f1.keyId,
          LogicalKeyboardKey.help.keyId,
          LogicalKeyboardKey.tvContentsMenu.keyId,
          LogicalKeyboardKey.mediaTopMenu.keyId,
        },
        RemoteAction.playPause: {
          LogicalKeyboardKey.mediaPlay.keyId,
          LogicalKeyboardKey.mediaPause.keyId,
          LogicalKeyboardKey.mediaPlayPause.keyId,
        },
        RemoteAction.fastForward: {
          LogicalKeyboardKey.mediaFastForward.keyId,
        },
        RemoteAction.rewind: {
          LogicalKeyboardKey.mediaRewind.keyId,
        },
        RemoteAction.nextEpisode: {
          LogicalKeyboardKey.mediaTrackNext.keyId,
          LogicalKeyboardKey.channelUp.keyId,
          LogicalKeyboardKey.pageDown.keyId,
        },
        RemoteAction.prevEpisode: {
          LogicalKeyboardKey.mediaTrackPrevious.keyId,
          LogicalKeyboardKey.channelDown.keyId,
          LogicalKeyboardKey.pageUp.keyId,
        },
      });

  /// 该动作绑定的所有物理键。
  Set<LogicalKeyboardKey> keysOf(RemoteAction action) =>
      (_bindings[action] ?? const {})
          .map((id) => LogicalKeyboardKey.findKeyByKeyId(id))
          .whereType<LogicalKeyboardKey>()
          .toSet();

  /// 该动作绑定的所有 keyId。
  Set<int> keyIdsOf(RemoteAction action) => _bindings[action] ?? const {};

  /// 判断 [key] 是否触发 [action]。
  bool matches(RemoteAction action, LogicalKeyboardKey key) {
    final ids = _bindings[action];
    return ids != null && ids.contains(key.keyId);
  }

  /// 查找该按键当前所绑定的动作（用于按键测试与冲突检测）。
  RemoteAction? findActionForKey(LogicalKeyboardKey key) {
    for (final entry in _bindings.entries) {
      if (entry.value.contains(key.keyId)) {
        return entry.key;
      }
    }
    return null;
  }

  /// 给 [action] 追加一个物理键（去重）。返回新映射。
  RemoteKeyMap addKey(RemoteAction action, int keyId) {
    final next = Map<RemoteAction, Set<int>>.from(_bindings);
    final set = Set<int>.from(next[action] ?? const {});
    set.add(keyId);
    next[action] = set;
    return RemoteKeyMap(next);
  }

  /// 仅保留该物理键，覆盖 [action] 的旧绑定。返回新映射。
  RemoteKeyMap setKey(RemoteAction action, int keyId) {
    final next = Map<RemoteAction, Set<int>>.from(_bindings);
    next[action] = {keyId};
    return RemoteKeyMap(next);
  }

  /// 移除 [action] 的指定物理键。返回新映射。
  RemoteKeyMap removeKey(RemoteAction action, int keyId) {
    final next = Map<RemoteAction, Set<int>>.from(_bindings);
    final set = Set<int>.from(next[action] ?? const {});
    set.remove(keyId);
    next[action] = set;
    return RemoteKeyMap(next);
  }

  /// 清空 [action] 的所有绑定。返回新映射。
  RemoteKeyMap clearAction(RemoteAction action) {
    final next = Map<RemoteAction, Set<int>>.from(_bindings);
    next[action] = const {};
    return RemoteKeyMap(next);
  }

  /// 重置为默认映射。
  factory RemoteKeyMap.reset() => RemoteKeyMap.defaults();

  /// 该动作当前绑定的按键数量。
  int countOf(RemoteAction action) => _bindings[action]?.length ?? 0;

  /// 该动作绑定的按键可读名称（用于设置页展示）。
  /// 多个键用「/」分隔，无绑定显示「未设置」。
  String labelOf(RemoteAction action) {
    final keys = keysOf(action);
    if (keys.isEmpty) return '未设置';
    return keys.map((k) => keyName(k)).join(' / ');
  }

  /// 生成可读按键名：优先用 keyLabel，去掉冗余前缀，未知键显示 keyId。
  static String keyName(LogicalKeyboardKey k) {
    var label = k.keyLabel.trim();
    if (label.isEmpty) return '键 0x${k.keyId.toRadixString(16)}';
    label = label
        .replaceFirst('Game Button ', '')
        .replaceFirst('TV ', '')
        .replaceFirst('Media ', '');
    return label;
  }

  /// 根据 keyId 生成可读按键名。
  static String keyNameById(int keyId) {
    final key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    if (key == null) return '键 0x${keyId.toRadixString(16)}';
    return keyName(key);
  }

  Map<String, dynamic> toJson() => {
        for (final entry in _bindings.entries)
          entry.key.name: entry.value.toList()..sort(),
      };

  factory RemoteKeyMap.fromJson(Map<String, dynamic> json) {
    final bindings = <RemoteAction, Set<int>>{};
    for (final action in RemoteAction.values) {
      final raw = json[action.name];
      if (raw is List) {
        bindings[action] = raw
            .whereType<num>()
            .map((n) => n.toInt())
            .where((id) => id != 0)
            .toSet();
      } else {
        // 如果旧数据没有新动作的字段，自动填入默认值以防功能失效
        bindings[action] = RemoteKeyMap.defaults().keyIdsOf(action);
      }
    }
    return RemoteKeyMap(bindings);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteKeyMap && _deepEquals(_bindings, other._bindings);

  @override
  int get hashCode => Object.hashAll(
      _bindings.entries.map((e) => Object.hash(e.key, Object.hashAll(e.value))));

  static bool _deepEquals(
      Map<RemoteAction, Set<int>> a, Map<RemoteAction, Set<int>> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      final av = a[key], bv = b[key];
      if (av == null ||
          bv == null ||
          av.length != bv.length ||
          !av.containsAll(bv)) {
        return false;
      }
    }
    return true;
  }
}
