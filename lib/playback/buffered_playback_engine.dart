import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/playback_source.dart';
import 'playback_engine.dart';

final class _Slot {
  _Slot(this.engine, {this.source, this.episodeId});

  final PlaybackEngine engine;
  PlaybackSource? source;
  String? episodeId;
  Future<void> opened = Future.value();
  Future<void>? disposal;
  bool get disposed => disposal != null;
}

/// Keeps one paused native player ready to become the foreground player.
/// Promotion retains its demuxed media buffer, decoder and video surface.
class BufferedPlaybackEngine
    implements PlaybackEngine, PreloadingPlaybackEngine {
  BufferedPlaybackEngine(this._createEngine) {
    _active = _Slot(_createEngine(false));
    _active.engine.state.addListener(_activeChanged);
  }

  final PlaybackEngine Function(bool preloading) _createEngine;
  late _Slot _active;
  _Slot? _standby;
  int _preloadGeneration = 0;
  bool _disposed = false;
  bool _stopped = true;
  double _volume = 1;
  double _rate = 1;
  Future<void> _operations = Future.value();
  Future<void> _retirements = Future.value();
  Future<void>? _closing;

  @override
  final ValueNotifier<EngineSnapshot> state = ValueNotifier(
    const EngineSnapshot(),
  );

  /// Surfaces change before the first frame, allowing adjacent pages to mount.
  final ValueNotifier<int> videoChanges = ValueNotifier(0);
  PlaybackEngine get activeEngine => _active.engine;
  String? get activeEpisodeId => _active.episodeId;
  String? get preloadedEpisodeId => _standby?.episodeId;

  /// Returns true if the standby engine is preloaded for the specified episode and ready to promote.
  bool hasPreloadFor(String episodeId) {
    final prepared = _standby;
    return prepared != null &&
        prepared.episodeId == episodeId &&
        !prepared.disposed &&
        prepared.engine.state.value.error == null;
  }

  PlaybackEngine? engineForEpisode(String episodeId) {
    if (_active.episodeId == episodeId) return _active.engine;
    final standby = _standby;
    return standby?.episodeId == episodeId ? standby?.engine : null;
  }

  void _activeChanged() {
    if (!_disposed) state.value = _active.engine.state.value;
  }

  void _surfacesChanged() {
    if (!_disposed) videoChanges.value++;
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _retire(_Slot slot) {
    if (slot.disposed) return;
    final disposal = slot.engine.dispose().then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    slot.disposal = disposal;
    _retirements = Future.wait<void>([_retirements, disposal]).then((_) {});
  }

  @override
  void discardPreload() {
    ++_preloadGeneration;
    final old = _standby;
    _standby = null;
    if (old != null) {
      _retire(old);
      _surfacesChanged();
    }
  }

  @override
  Future<void> preload(
    PlaybackSource source, {
    required String episodeId,
  }) async {
    if (_disposed) return;
    if (_standby?.episodeId == episodeId &&
        identical(_standby?.source, source)) {
      return;
    }
    discardPreload();
    final generation = _preloadGeneration;
    // Do not create a third decoder while the previous one is being released.
    await _retirements;
    if (_disposed || generation != _preloadGeneration) return;
    final _Slot slot;
    try {
      slot = _Slot(_createEngine(true), episodeId: episodeId, source: source);
    } on Object {
      return;
    }
    _standby = slot;
    bool valid() =>
        !_disposed &&
        !slot.disposed &&
        (identical(_standby, slot) || identical(_active, slot));
    slot.opened = (() async {
      await slot.engine.setVolume(0);
      if (!valid()) return;
      await slot.engine.open(
        source,
        start: Duration.zero,
        isCurrent: valid,
        episodeId: episodeId,
      );
    })();
    _surfacesChanged();
    try {
      await slot.opened;
    } on Object {
      // Preloading must never interrupt the episode being watched.
      if (identical(_standby, slot)) {
        _standby = null;
        _retire(slot);
        _surfacesChanged();
      }
    }
  }

  @override
  Future<void> open(
    PlaybackSource source, {
    required Duration start,
    required bool Function() isCurrent,
    String? episodeId,
  }) => _serialize(() async {
    bool valid() => !_disposed && isCurrent();
    if (!valid()) return;
    final prepared = _standby;
    final canPromote =
        prepared != null &&
        (identical(prepared.source, source) ||
            prepared.source?.uri == source.uri) &&
        prepared.episodeId == episodeId &&
        start == Duration.zero &&
        prepared.engine.state.value.error == null;
    if (canPromote && !_stopped) {
      await _active.engine.stop();
      _stopped = true;
    }
    if (!valid()) return;
    // Backgrounding or memory pressure can discard the candidate while stop
    // is in flight. Never promote an engine which has already been released.
    if (canPromote && identical(_standby, prepared) && !prepared.disposed) {
      final old = _active;
      old.engine.state.removeListener(_activeChanged);
      _standby = null;
      ++_preloadGeneration;
      _active = prepared;
      _active.engine.state.addListener(_activeChanged);
      _activeChanged();
      _surfacesChanged();
      _retire(old);
      await prepared.opened;
      if (!valid()) {
        await prepared.engine.stop();
        _stopped = true;
        return;
      }
      await prepared.engine.setVolume(_volume);
      await prepared.engine.setRate(_rate);
    } else {
      discardPreload();
      _active.source = source;
      _active.episodeId = episodeId;
      _surfacesChanged();
      await _active.engine.open(
        source,
        start: start,
        isCurrent: valid,
        episodeId: episodeId,
      );
    }
    _stopped = false;
    _activeChanged();
  });

  @override
  Future<void> stop() => _serialize(() async {
    if (_disposed) return;
    await _active.engine.stop();
    _stopped = true;
  });

  @override
  Future<void> setPlaying(bool playing) async {
    if (!_disposed) await _active.engine.setPlaying(playing);
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_disposed) await _active.engine.seek(position);
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    if (!_disposed) await _active.engine.setRate(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    if (!_disposed) await _active.engine.setVolume(volume);
  }

  @override
  Future<void> dispose() => _closing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _active.engine.state.removeListener(_activeChanged);
    discardPreload();
    await _operations;
    _retire(_active);
    await _retirements;
    videoChanges.dispose();
    state.dispose();
  }
}
