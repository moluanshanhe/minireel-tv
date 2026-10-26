import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/models/playback_source.dart';
import 'hongguo_app_client.dart';
import 'hongguo_parser.dart';
import 'hongguo_playback_codec.dart';

final class HongguoMediaService {
  HongguoMediaService(this.client, this.config);
  final HongguoAppClient client;
  final SourceConfig config;

  Future<PlaybackOptions> resolve(
    String videoId, {
    CancelToken? cancelToken,
  }) async {
    dynamic value;
    try {
      final result = await client.post('/novel/player/video_model/v1/', {
        'video_id': videoId,
        'content_type': 1,
        'biz_param': {'need_all_video_definition': true, 'video_platform': 3},
      }, cancelToken: cancelToken);
      value = objectMap(result['data'])['video_model'];
    } catch (_) {
      cancelToken?.throwIfCancellationRequested();
    }

    if (value == null) {
      try {
        final result = await client.post(
          '/novel/player/multi_video_model/preload/v1',
          {
            'biz_param': {
              'detail_page_version': 0,
              'device_level': 3,
              'disable_digg_stat': false,
              'need_all_video_definition': true,
              'need_mp4_align': false,
              'use_os_player': false,
              'use_server_dns': false,
              'video_platform': 1024,
            },
            'dr_scene': 'preload',
            'mixed_video_id_map': {
              '1004': [videoId],
            },
          },
          cancelToken: cancelToken,
        );
        final data = objectMap(result['data']);
        final entry = objectMap(
          data[videoId] ??
              (data.isNotEmpty && !data.containsKey('video_model')
                  ? data.values.first
                  : null),
        );
        value = entry['video_model'] ?? data['video_model'];
      } catch (_) {
        cancelToken?.throwIfCancellationRequested();
      }
    }

    if (value == null) {
      throw const AppException('App 未返回视频播放数据');
    }
    try {
      return parse(objectMap(value is String ? jsonDecode(value) : value));
    } on FormatException {
      throw const AppException('App 播放信息格式异常');
    }
  }

  PlaybackOptions parse(Map<String, dynamic> model) {
    final rows = model['video_list'];
    final variants = rows is Map ? rows.values.toList() : anyList(rows);
    final seconds = double.tryParse(
      field(model, ['video_duration', 'duration']),
    );
    final duration = seconds != null && seconds.isFinite && seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : null;
    final sources = <({PlaybackSource source, int score})>[];
    final fallbackSources = <({PlaybackSource source, int score})>[];
    for (final row in variants) {
      final variant = objectMap(row);
      final meta = objectMap(variant['video_meta']);
      final codec = field(meta, ['codec_type']).toLowerCase();
      final isBytevc2 = codec == 'bytevc2' ||
          field(variant, ['gear_des_key']).toLowerCase().contains('bytevc2');
      final uri = mediaUri(field(variant, ['main_url']));
      if (uri == null) continue;
      final encryption = objectMap(variant['encrypt_info']);
      final spade = field(encryption, ['spade_a']);
      final encrypted =
          spade.isNotEmpty ||
          encryption['encrypt'] == true ||
          field(encryption, ['encryption_method']) == 'cenc-aes-ctr';
      try {
        final key = encrypted
            ? const HongguoPlaybackCodec().decodeContentKey(spade)
            : null;
        final definition = int.tryParse(
          RegExp(r'\d+').firstMatch(field(meta, ['definition']))?.group(0) ??
              '',
        );
        final height =
            definition ?? int.tryParse(field(meta, ['vheight'])) ?? 0;
        final candidate = (
          source: PlaybackSource(
            uri: uri,
            kind: encrypted
                ? PlaybackKind.cenc
                : uri.path.toLowerCase().contains('.m3u8')
                ? PlaybackKind.hls
                : PlaybackKind.direct,
            headers: config.playbackHeaders(mediaReferer: config.mediaReferer),
            duration: duration,
            contentKey: key,
            route: PlaybackRoute.app,
            quality: height > 0 ? '${height}P' : '原画',
          ),
          score:
              height * 10 + (['h264', 'avc1', 'avc'].contains(codec) ? 1 : 0),
        );
        if (isBytevc2) {
          fallbackSources.add(candidate);
        } else {
          sources.add(candidate);
        }
      } on AppException {
        // A broken encrypted variant must not hide other playable variants.
        continue;
      }
    }
    final effective = sources.isNotEmpty ? sources : fallbackSources;
    effective.sort((a, b) => b.score.compareTo(a.score));
    if (effective.isEmpty) throw const AppException('App 未返回兼容的媒体');
    final qualities = <String>{};
    return PlaybackOptions([
      for (final item in effective)
        if (qualities.add(item.source.quality)) item.source,
    ]);
  }
}
