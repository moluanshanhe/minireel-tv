import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../domain/models/drama.dart';
import '../../../domain/models/playback_source.dart';
import '../source_adapter.dart';
import 'hongguo_parser.dart';
import 'hongguo_playback_codec.dart';

final class HongguoWebFallback implements DramaSourceAdapter {
  HongguoWebFallback(this.config, this.client);
  final SourceConfig config;
  final TextClient client;
  final parser = const HongguoParser();
  final codec = const HongguoPlaybackCodec();

  @override
  String get id => 'hongguo';
  @override
  String get displayName => '红果剧库';
  @override
  int get maxPages => config.maxPages;
  @override
  int get pageSize => config.pageSize;

  @override
  Future<List<Drama>> fetchCatalog(
    DramaChannel channel,
    int page, {
    CancelToken? cancelToken,
  }) async {
    final uri = config.baseUrl
        .resolve('/category/${channel.route}')
        .replace(queryParameters: {'page': '$page'});
    return parser.catalog(
      await client.getText(uri, cancelToken: cancelToken),
      channel,
    );
  }

  @override
  Future<DramaDetail> fetchDetail(
    Drama drama, {
    CancelToken? cancelToken,
  }) async {
    final uri = config.baseUrl
        .resolve('/detail')
        .replace(queryParameters: {'series_id': drama.sourceId});
    return parser.detail(
      await client.getText(uri, cancelToken: cancelToken),
      drama,
    );
  }

  @override
  Future<PlaybackOptions> resolvePlayback(
    Drama drama,
    Episode episode, {
    CancelToken? cancelToken,
    bool fallbackOnly = false,
  }) async {
    if (episode.dramaId != drama.id ||
        !RegExp(r'^[0-9]{1,32}$').hasMatch(drama.sourceId) ||
        !RegExp(r'^[0-9]{1,32}$').hasMatch(episode.sourceEpisodeId)) {
      throw const AppException('分集信息已失效，请刷新短剧后重试');
    }
    if (fallbackOnly) return _fromApi(drama, episode, cancelToken);
    try {
      return PlaybackOptions([await _fromWeb(drama, episode, cancelToken)]);
    } on AppException {
      // Only expected provider failures fall back. Cancellation/programming
      // errors are never converted into a second request.
      cancelToken?.throwIfCancellationRequested();
      return _fromApi(drama, episode, cancelToken);
    }
  }

  Future<PlaybackSource> _fromWeb(
    Drama drama,
    Episode episode,
    CancelToken? token,
  ) async {
    final uri = config.baseUrl.resolve(
      '/player/${drama.sourceId}/${episode.sourceEpisodeId}',
    );
    final html = await client.getText(uri, cancelToken: token);
    final page = parser.loader(parser.routerData(html), [
      'player_page',
      'player_',
    ]);
    // A returned preview of episode one must never masquerade as another episode.
    if (field(page, ['vid']) != episode.sourceEpisodeId ||
        field(page, ['series_id']) != drama.sourceId) {
      throw const AppException('网页未返回所选分集');
    }
    final info = objectMap(page['video_player_info']);
    var rawUrl = field(info, ['main_url']);
    if (rawUrl.isEmpty) {
      final ldMatch = RegExp(r'"contentUrl"\s*:\s*"([^"]+)"').firstMatch(html);
      if (ldMatch != null) {
        rawUrl = ldMatch.group(1)?.replaceAll(r'\/', '/') ?? '';
      }
    }
    final media = mediaUri(rawUrl);
    if (media == null) throw const AppException('网页暂未提供本集播放地址');
    final seconds = double.tryParse(field(info, ['duration']));
    return PlaybackSource(
      uri: media,
      kind: media.path.toLowerCase().contains('.m3u8')
          ? PlaybackKind.hls
          : PlaybackKind.direct,
      headers: config.playbackHeaders(),
      duration: seconds != null && seconds.isFinite && seconds > 0
          ? Duration(milliseconds: (seconds * 1000).round())
          : null,
    );
  }

  Future<PlaybackOptions> _fromApi(
    Drama drama,
    Episode episode,
    CancelToken? token,
  ) async {
    final reference = base64.encode(
      utf8.encode(
        jsonEncode({
          'content_type': 1004,
          'from_video_id': '',
          'series_id': drama.sourceId,
          'vid': episode.sourceEpisodeId,
          'video_platform': 3,
        }),
      ),
    );
    final uri = config.playbackEndpoint.replace(
      queryParameters: {
        ...config.playbackEndpoint.queryParameters,
        'id': reference,
      },
    );
    final body = await client.getText(uri, cancelToken: token);
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(codec.decodeResponse(body)));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      data = decoded;
    } on FormatException {
      throw const AppException('播放数据暂时无法读取，请稍后重试', kind: FailureKind.parsing);
    }
    for (final key in ['parse', 'jx']) {
      if (![null, false, 0, '0', ''].contains(data[key])) {
        throw const AppException('本集暂未提供可用的播放地址');
      }
    }
    // The service sometimes echoes the base64 request as `url` with parse=0.
    // That is a failed resolution, not a media URL to decode or open.
    if (field(data, ['url']) == reference) {
      throw const AppException('片源暂未提供这集的视频地址，请尝试其他短剧或稍后重试');
    }
    final options = <PlaybackSource>[];
    AppException? keyError;
    for (final entry in anyList(data['key_urls'])) {
      final option = objectMap(entry);
      final media = mediaUri(field(option, ['src']));
      final kid = field(option, ['kid']);
      if (media == null || !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(kid)) {
        keyError ??= const AppException('本集播放信息不完整，请稍后重试');
        continue;
      }
      try {
        final key = codec.decodeContentKey(field(option, ['spade_a']));
        final name = field(option, ['name']);
        final quality = RegExp(r'[0-9]+').firstMatch(name)?.group(0);
        options.add(
          PlaybackSource(
            uri: media,
            kind: PlaybackKind.cenc,
            headers: config.playbackHeaders(mediaReferer: config.mediaReferer),
            contentKey: key,
            keyId: kid,
            route: PlaybackRoute.fallback,
            quality: quality == null
                ? (name.isEmpty ? '原画' : name)
                : '${quality}P',
          ),
        );
      } on AppException catch (error) {
        keyError = error;
        // An invalid quality option must not discard another valid option.
        continue;
      }
    }
    // Plain media responses are valid only when the service returns an actual
    // HTTP(S) URL, not a request reference or incomplete encryption material.
    if (options.isEmpty && anyList(data['key_urls']).isEmpty) {
      final direct = mediaUri(field(data, ['url']));
      if (direct != null) {
        options.add(
          PlaybackSource(
            uri: direct,
            kind: direct.path.toLowerCase().contains('.m3u8')
                ? PlaybackKind.hls
                : PlaybackKind.direct,
            headers: config.playbackHeaders(mediaReferer: config.mediaReferer),
            route: PlaybackRoute.fallback,
          ),
        );
      }
    }
    if (options.isEmpty) throw keyError ?? const AppException('本集暂时无法播放，请稍后重试');
    int qualityOf(PlaybackSource source) =>
        int.tryParse(
          RegExp(r'\d+').firstMatch(source.quality)?.group(0) ?? '',
        ) ??
        0;
    options.sort((a, b) => qualityOf(b).compareTo(qualityOf(a)));
    return PlaybackOptions(options);
  }
}
