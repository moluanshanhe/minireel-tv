import 'package:dio/dio.dart';

import '../core/network/app_http_client.dart';
import '../domain/models/playback_source.dart';

/// One transient playback resolution, never media bytes or disk storage.
final class NextEpisodePrefetch {
  NextEpisodePrefetch({
    this.ttl = const Duration(minutes: 15),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final Duration ttl;
  final DateTime Function() _now;
  String? _id;
  DateTime? _expires;
  CancelToken? _token;
  Future<PlaybackOptions?>? _result;

  bool get expired => _expires != null && !_now().isBefore(_expires!);

  void start(String id, Future<PlaybackOptions> Function(CancelToken) resolve) {
    if (_id == id && _expires != null && _now().isBefore(_expires!)) return;
    clear();
    final token = _token = CancelToken();
    _id = id;
    _expires = _now().add(ttl);
    _result = (() async {
      try {
        final result = await resolve(token);
        token.throwIfCancellationRequested();
        return result;
      } on Exception {
        if (_id == id) {
          clear();
        }
        return null;
      }
    })();
  }

  Future<PlaybackOptions?> take(String id, CancelToken cancelToken) async {
    if (_id != id || _expires == null || !_now().isBefore(_expires!)) {
      clear();
      return null;
    }
    final result = _result!;
    final token = _token!;
    _id = null;
    _expires = null;
    _token = null;
    _result = null;
    try {
      cancelToken.throwIfCancellationRequested();
      return await Future.any<PlaybackOptions?>([
        result,
        cancelToken.whenCancel.then<PlaybackOptions?>((error) => throw error),
      ]);
    } finally {
      token.cancel();
    }
  }

  void clear() {
    _token?.cancel();
    _id = null;
    _expires = null;
    _token = null;
    _result = null;
  }
}
