import '../../domain/models/drama.dart';
import '../../domain/models/catalog_page.dart';
import '../../domain/models/preferences.dart';
import '../../domain/models/watch_record.dart';

/// Optional persistent source state; old adapters/stores remain compatible.
abstract interface class SourceStateStore {
  Future<Map<String, dynamic>?> readSourceState(String key);
  Future<Map<String, Map<String, dynamic>>> readSourceStatesByPrefix(
    String prefix,
  );
  Future<void> saveSourceState(String key, Map<String, dynamic> value);
  Future<void> saveCatalogPage(
    String key,
    List<Drama> dramas,
    CatalogCursor cursor,
    bool hasMore,
  );
}

abstract interface class AppStore {
  Future<List<Drama>> readCatalog();
  Future<void> saveCatalog(List<Drama> dramas);
  Future<DramaDetail?> readDetail(String dramaId);
  Future<void> saveDetail(DramaDetail detail);
  Future<Preferences> readPreferences();
  Future<void> savePreferences(Preferences preferences);
  Future<List<Drama>> readFavorites();
  Future<void> setFavorite(Drama drama, bool favorite);
  Future<List<WatchRecord>> readHistory();
  Future<void> saveRecord(WatchRecord record);
  Future<void> deleteHistory(Iterable<String> dramaIds);
  Future<List<String>> readSearches();
  Future<void> saveSearches(List<String> searches);
  Future<DateTime?> readLastRefresh();
  Future<void> saveLastRefresh(DateTime time);
  Future<int> cacheBytes();
  Future<void> clearCache();
  Future<void> close();
}
