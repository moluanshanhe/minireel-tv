import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../domain/models/catalog_page.dart';
import '../../../domain/models/drama.dart';
import '../../../domain/models/playback_source.dart';
import '../../../domain/models/discovery.dart';
import '../../local/app_store.dart';
import '../source_adapter.dart';
import 'hongguo_app_client.dart';
import 'hongguo_catalog_service.dart';
import 'hongguo_detail_service.dart';
import 'hongguo_media_service.dart';
import 'hongguo_web_fallback.dart';
import 'hongguo_search_service.dart';
import 'hongguo_ranking_service.dart';

final class HongguoAdapter
    implements
        DramaSourceAdapter,
        CursorCatalogSource,
        RoutedPlaybackSource,
        SourceCacheControl,
        RemoteSearchSource,
        RankingSource {
  HongguoAdapter(this.config, this.client, {SourceStateStore? store}) {
    final app = HongguoAppClient(config, client, store: store);
    web = HongguoWebFallback(config, client);
    catalogService = HongguoCatalogService(app, web);
    detailService = HongguoDetailService(app);
    mediaService = HongguoMediaService(app, config);
    searchService = HongguoSearchService(config, client);
    rankingService = HongguoRankingService(config, client);
  }
  final SourceConfig config;
  final TextClient client;
  late final HongguoWebFallback web;
  late final HongguoCatalogService catalogService;
  late final HongguoDetailService detailService;
  late final HongguoMediaService mediaService;
  late final HongguoSearchService searchService;
  late final HongguoRankingService rankingService;

  @override
  Future<SearchResult> searchRemote(
    String keyword, {
    CancelToken? cancelToken,
  }) => searchService.search(keyword, cancelToken: cancelToken);

  @override
  Future<RankingPage> getRanking(
    RankingType type, {
    int page = 1,
    bool refresh = false,
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await rankingService.load(
        type,
        page: page,
        refresh: refresh,
        cancelToken: cancelToken,
      );
      if (res.items.isNotEmpty) return res;
    } on AppException catch (e) {
      if (e.kind == FailureKind.cancelled) rethrow;
    } catch (_) {}

    return _fallbackRanking(type, page, cancelToken: cancelToken);
  }

  Future<RankingPage> _fallbackRanking(
    RankingType type,
    int page, {
    CancelToken? cancelToken,
  }) async {
    final channel = switch (type) {
      RankingType.hot => DramaChannel.real,
      RankingType.realDrama => DramaChannel.real,
      RankingType.comicDrama => DramaChannel.comicDrama,
      RankingType.aiDrama => DramaChannel.ai,
    };
    try {
      final catalog = await loadCatalog(
        channel,
        refresh: page == 1,
        cancelToken: cancelToken,
      );
      final start = (page - 1) * pageSize;
      final end = (start + pageSize).clamp(0, catalog.items.length);
      final slice = (start < catalog.items.length)
          ? catalog.items.sublist(start, end)
          : <Drama>[];
      return RankingPage(
        type: type,
        page: page,
        items: [
          for (var i = 0; i < slice.length; i++)
            RankingItem(
              rank: start + i + 1,
              metric: slice[i].heat > 0 ? '${slice[i].heat}热度' : '',
              drama: slice[i],
            ),
        ],
        totalPages: maxPages,
        updatedText: '精选热播推荐',
      );
    } catch (_) {
      return RankingPage(
        type: type,
        page: page,
        items: const [],
        totalPages: 1,
      );
    }
  }

  @override
  void clearTransientCache() {
    detailService.clear();
    searchService.clear();
    rankingService.clear();
    catalogService.webFallbackActive = false;
  }

  @override
  String get id => 'hongguo';
  @override
  String get displayName => '红果剧库';
  @override
  int get maxPages => config.maxPages;
  @override
  int get pageSize => config.pageSize;
  @override
  List<DramaChannel> get catalogChannels => [
    DramaChannel.real,
    DramaChannel.comicDrama,
    DramaChannel.ai,
    if (!catalogService.client.enabled || catalogService.webFallbackActive)
      DramaChannel.animation,
  ];

  @override
  Future<CatalogPage> loadCatalog(
    DramaChannel channel, {
    CatalogCursor cursor = const CatalogCursor(),
    bool refresh = false,
    Set<String> knownIds = const {},
    CancelToken? cancelToken,
  }) => catalogService.load(
    channel,
    cursor,
    refresh: refresh,
    knownIds: knownIds,
    cancelToken: cancelToken,
  );

  // Compatibility for page-based consumers; the repository uses loadCatalog.
  @override
  Future<List<Drama>> fetchCatalog(
    DramaChannel channel,
    int page, {
    CancelToken? cancelToken,
  }) => web.fetchCatalog(channel, page, cancelToken: cancelToken);

  @override
  Future<DramaDetail> fetchDetail(
    Drama drama, {
    CancelToken? cancelToken,
  }) async {
    _validateId(drama.sourceId);
    try {
      return await detailService.getDetail(drama, cancelToken: cancelToken);
    } on AppException {
      cancelToken?.throwIfCancellationRequested();
      return web.fetchDetail(drama, cancelToken: cancelToken);
    }
  }

  @override
  Future<PlaybackOptions> resolvePlayback(
    Drama drama,
    Episode episode, {
    CancelToken? cancelToken,
    bool fallbackOnly = false,
  }) => resolveFrom(
    drama,
    episode,
    start: fallbackOnly ? PlaybackRoute.fallback : PlaybackRoute.app,
    cancelToken: cancelToken,
  );

  @override
  Future<PlaybackOptions> resolveFrom(
    Drama drama,
    Episode episode, {
    PlaybackRoute start = PlaybackRoute.app,
    CancelToken? cancelToken,
  }) async {
    _validateId(drama.sourceId);
    _validateId(episode.sourceEpisodeId);
    if (episode.dramaId != drama.id) {
      throw const AppException('分集信息已失效，请刷新短剧后重试');
    }
    cancelToken?.throwIfCancellationRequested();
    if (start == PlaybackRoute.app) {
      try {
        return await mediaService.resolve(
          episode.sourceEpisodeId,
          cancelToken: cancelToken,
        );
      } on AppException {
        cancelToken?.throwIfCancellationRequested();
      }
    }
    return web.resolvePlayback(
      drama,
      episode,
      cancelToken: cancelToken,
      fallbackOnly: start == PlaybackRoute.fallback,
    );
  }

  void _validateId(String id) {
    if (!RegExp(r'^[0-9]{1,32}$').hasMatch(id)) {
      throw const AppException('剧集信息已失效，请刷新后重试');
    }
  }
}
