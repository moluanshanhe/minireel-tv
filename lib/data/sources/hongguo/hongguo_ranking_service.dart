import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../core/network/request_cache.dart';
import '../../../domain/models/discovery.dart';
import '../../../domain/models/drama.dart';
import 'hongguo_metadata.dart';
import 'hongguo_parser.dart';

final class HongguoRankingService {
  HongguoRankingService(this.config, this.client);
  final SourceConfig config;
  final TextClient client;
  final _cache = RequestCache<RankingPage>(capacity: 128);
  void clear() => _cache.clear();
  static const _boards = {
    RankingType.hot: (
      path: 'hot-drama',
      key: 'hongguo',
      channel: DramaChannel.real,
    ),
    RankingType.realDrama: (
      path: 'hot-real-drama',
      key: 'real',
      channel: DramaChannel.real,
    ),
    RankingType.comicDrama: (
      path: 'hot-comic-drama',
      key: 'comic',
      channel: DramaChannel.comicDrama,
    ),
    RankingType.aiDrama: (
      path: 'hot-ai-drama',
      key: 'ai',
      channel: DramaChannel.ai,
    ),
  };

  Future<RankingPage> load(
    RankingType type, {
    int page = 1,
    bool refresh = false,
    CancelToken? cancelToken,
  }) {
    if (page < 1 || page > 500) throw const AppException('榜单页码无效');
    if (refresh) _cache.clear(prefix: '${type.name}:');
    return _cache.get('${type.name}:$page', (token) async {
      final uri = config.baseUrl
          .resolve('/rank/${_boards[type]!.path}')
          .replace(queryParameters: {'page': '$page'});
      return parse(await client.getText(uri, cancelToken: token), type, page);
    }, cancelToken: cancelToken);
  }

  RankingPage parse(String html, RankingType type, int page) {
    const failure = AppException('榜单格式或分页已变化，请稍后重试');
    final board = _boards[type]!;
    final route = 'rank_${board.path}/page';

    // 1. 尝试从 Modern.js 脚本或 _ROUTER_DATA 中解析 JSON
    Map<String, dynamic> loader = {};
    try {
      final routerData = const HongguoParser().routerData(html);
      loader = objectMap(objectMap(routerData['loaderData'])[route]);
    } catch (_) {}

    // 如果 loader 中有显式标识，校验是否匹配（如缺失则宽容处理）
    final rankKey = field(loader, ['rankKey']);
    final pageNum = field(loader, ['pageNum']);
    if (rankKey.isNotEmpty && rankKey != board.key) throw failure;
    if (pageNum.isNotEmpty && pageNum != '$page') throw failure;

    var content = objectMap(loader['content']);
    if (content.isEmpty) {
      for (final tag in RegExp(
        r'<script\b[^>]*>',
        caseSensitive: false,
        dotAll: true,
      ).allMatches(html)) {
        final attrs = _attributes(tag[0]!);
        final fnName = attrs['data-fn-name'];
        final scriptSrc = attrs['data-script-src'];

        // 1.1 Modern.js 新版 mergeLoaderData
        if (fnName == 'mergeLoaderData' ||
            scriptSrc == 'modern-run-window-fn') {
          try {
            final args = jsonDecode(attrs['data-fn-args'] ?? 'null');
            if (args is List &&
                args.length >= 2 &&
                args[0] == route &&
                args[1] is List) {
              for (final entry in args[1]) {
                if (entry is Map && entry['key'] == 'content') {
                  final fnArgs = entry['routerDataFnArgs'];
                  if (fnArgs is List && fnArgs.isNotEmpty) {
                    final first = fnArgs[0];
                    if (first is Map) {
                      content = objectMap(first);
                      break;
                    } else if (first is String &&
                        first.trimLeft().startsWith('{')) {
                      final decoded = jsonDecode(first);
                      if (decoded is Map) {
                        content = objectMap(decoded);
                        break;
                      }
                    }
                  }
                }
              }
            }
          } catch (_) {}
          if (content.isNotEmpty) break;
        }

        // 1.2 兼容旧版 r 函数 routerData
        if (fnName == 'r' && scriptSrc == 'modern-run-router-data-fn') {
          try {
            final args = jsonDecode(attrs['data-fn-args'] ?? 'null');
            if (args is List &&
                args.length == 3 &&
                args[0] == route &&
                args[1] == 'content') {
              content = objectMap(args[2]);
              break;
            }
          } on FormatException {
            continue;
          }
        }
      }
    }

    // 2. 如果成功从 JSON 提取到 rankList，按结构化数据解析
    final pagination = objectMap(content['pagination']);
    final totalPages = int.tryParse(field(pagination, ['totalPages'])) ?? 0;
    final rows = content['rankList'];
    if (content['isSuccess'] == true && rows is List && rows.isNotEmpty) {
      final pNum = field(pagination, ['pageNum']);
      if (pNum.isNotEmpty && pNum != '$page') {
        throw failure;
      }
      final seen = <String>{};
      final items = <RankingItem>[];
      var previous = (page - 1) * 20;
      for (final value in rows) {
        final row = objectMap(value);
        final id = field(row, ['seriesId', 'id']);
        final oldId = field(row, ['id']);
        final rank = int.tryParse(field(row, ['rank'])) ?? (previous + 1);
        final title = field(row, ['title']);
        if (!RegExp(r'^[0-9]{1,32}$').hasMatch(id) ||
            (oldId.isNotEmpty && oldId != id) ||
            title.isEmpty ||
            rank <= previous ||
            rank > page * 20 ||
            !seen.add(id)) {
          throw failure;
        }
        previous = rank;
        final tags = stringList(row['tags']);
        final metric = field(row, ['heatText']);
        items.add(
          RankingItem(
            rank: rank,
            metric: metric,
            drama: Drama(
              id: 'hongguo:$id',
              source: 'hongguo',
              sourceId: id,
              title: title,
              coverUrl: field(row, [
                'series_cover',
                'cover',
                'coverUrl',
                'img',
                'poster',
                'thumb',
                'coverImg',
              ]),
              intro: field(row, ['description']),
              tags: tags,
              category: tags.isEmpty ? '' : tags.first,
              episodeCount: anyList(row['episodeVids']).length,
              channel: board.channel,
              heat: hongguoNumber(metric),
              score: hongguoNumber(field(row, ['scoreText'])),
            ),
          ),
        );
      }
      return RankingPage(
        type: type,
        page: page,
        items: items,
        totalPages: totalPages > 0 ? totalPages : (page + 1),
        updatedText: field(loader, ['updatedText']),
      );
    }

    // 3. JSON 不可用时（例如服务端流式渲染 SSR 仅下发 HTML DOM），从 HTML DOM 提取
    final domItems = _parseFromDom(html, board.channel, page);
    if (domItems.isNotEmpty) {
      final domTotalPages = _parseTotalPages(html, page, domItems.length);
      return RankingPage(
        type: type,
        page: page,
        items: domItems,
        totalPages: domTotalPages,
        updatedText: field(loader, ['updatedText']),
      );
    }

    throw failure;
  }

  List<RankingItem> _parseFromDom(String html, DramaChannel channel, int page) {
    final items = <RankingItem>[];
    final articles = RegExp(
      r'<article\b[^>]*>([\s\S]*?)</article>',
      caseSensitive: false,
    ).allMatches(html);

    final seen = <String>{};
    var previous = (page - 1) * 20;

    for (final match in articles) {
      final block = match.group(0)!;
      final sidMatch =
          RegExp(r'href="/detail\?series_id=(\d+)"').firstMatch(block);
      if (sidMatch == null) continue;
      final id = sidMatch.group(1)!;
      if (!seen.add(id)) continue;

      final titleMatch =
          RegExp(r'<h2\s+id="rank-title-\d+"[^>]*>([^<]+)</h2>')
              .firstMatch(block);
      final title = _unescape(titleMatch?.group(1)?.trim() ?? '');
      if (title.isEmpty) continue;

      final rankMatch =
          RegExp(r'class="pc-badge-number-[^"]*">(\d+)</span>')
              .firstMatch(block);
      final parsedRank = int.tryParse(rankMatch?.group(1) ?? '');
      final rank = (parsedRank != null && parsedRank > previous)
          ? parsedRank
          : previous + 1;
      previous = rank;

      final coverMatch =
          RegExp(r'<img\s+class="pc-cover-[^"]*"\s+src="([^"]+)"')
              .firstMatch(block);
      final coverUrl = coverMatch?.group(1) ?? '';

      final heatMatch =
          RegExp(r'<p\s+class="pc-metrics-[^"]*"[^>]*>[\s\S]*?([0-9.]+[万亿]?热度)')
              .firstMatch(block);
      final metric = heatMatch?.group(1) ?? '';

      final scoreMatch =
          RegExp(r'class="pc-score-tag-[^"]*"[^>]*>[\s\S]*?([0-9.]+)\s*</li>')
              .firstMatch(block);
      final scoreText = scoreMatch?.group(1) ?? '';

      final descMatch =
          RegExp(r'<p\s+class="pc-description-[^"]*"[^>]*>([^<]+)</p>')
              .firstMatch(block);
      final intro = _unescape(descMatch?.group(1)?.trim() ?? '');

      final catsMatch =
          RegExp(r'<p\s+class="pc-categories-[^"]*"[^>]*>([\s\S]*?)</p>')
              .firstMatch(block);
      final tags = <String>[];
      if (catsMatch != null) {
        for (final tagMatch in RegExp(r'<span>([^<]+)</span>')
            .allMatches(catsMatch.group(1)!)) {
          final t = _unescape(tagMatch.group(1)!.trim());
          if (t.isNotEmpty) tags.add(t);
        }
      }

      final epMatches = RegExp(r'class="pc-episode-[^"]*"').allMatches(block);
      final episodeCount = epMatches.length;

      items.add(
        RankingItem(
          rank: rank,
          metric: metric,
          drama: Drama(
            id: 'hongguo:$id',
            source: 'hongguo',
            sourceId: id,
            title: title,
            coverUrl: coverUrl,
            intro: intro,
            tags: tags,
            category: tags.isEmpty ? '' : tags.first,
            episodeCount: episodeCount,
            channel: channel,
            heat: hongguoNumber(metric),
            score: hongguoNumber(scoreText),
          ),
        ),
      );
    }
    return items;
  }

  int _parseTotalPages(String html, int page, int itemCount) {
    final pageMatches = RegExp(r'href="[^"]*[?&]page=(\d+)"').allMatches(html);
    var maxPage = page;
    for (final m in pageMatches) {
      final p = int.tryParse(m.group(1)!);
      if (p != null && p > maxPage && p <= 500) {
        maxPage = p;
      }
    }
    if (maxPage > page) return maxPage;
    return itemCount >= 20 ? page + 1 : page;
  }

  Map<String, String> _attributes(String tag) {
    final matches = RegExp(
      r'''([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
    ).allMatches(tag);
    return {
      for (final m in matches)
        m[1]!.toLowerCase(): _unescape(m[2] ?? m[3] ?? ''),
    };
  }

  String _unescape(String text) => text.replaceAllMapped(
    RegExp(r'&(#x[0-9a-fA-F]+|#\d+|quot|apos|amp|lt|gt);'),
    (m) {
      const named = {
        'quot': '"',
        'apos': "'",
        'amp': '&',
        'lt': '<',
        'gt': '>',
      };
      final entity = m[1]!;
      if (named.containsKey(entity)) return named[entity]!;
      final code = entity.startsWith('#x')
          ? int.tryParse(entity.substring(2), radix: 16)
          : int.tryParse(entity.substring(1));
      return code != null && code > 0 && code <= 0x10ffff
          ? String.fromCharCode(code)
          : m[0]!;
    },
  );
}
