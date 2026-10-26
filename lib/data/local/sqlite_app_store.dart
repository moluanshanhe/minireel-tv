import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../domain/models/drama.dart';
import '../../domain/models/catalog_page.dart';
import '../../domain/models/preferences.dart';
import '../../domain/models/watch_record.dart';
import 'app_store.dart';

/// The DatabaseFactory is injectable for the future Windows SQLite backend.
final class SqliteAppStore implements AppStore, SourceStateStore {
  SqliteAppStore._(this._db);
  final Database _db;

  static Future<SqliteAppStore> open({
    DatabaseFactory? factory,
    String? databasePath,
  }) async {
    if (factory == null && Platform.isWindows) {
      sqfliteFfiInit();
      factory = databaseFactoryFfi;
      if (databasePath == null) {
        final support = await getApplicationSupportDirectory();
        await support.create(recursive: true);
        databasePath = path.join(support.path, 'minireel.db');
      }
    }
    final backend = factory ?? mobile.databaseFactory;
    final file =
        databasePath ??
        path.join(await backend.getDatabasesPath(), 'minireel.db');
    final db = await backend.openDatabase(
      file,
      options: OpenDatabaseOptions(
        version: 1,
        // 不在打开数据库时强制执行 WAL、mmap 等可选性能参数。
        // 部分 Android TV/盒子的 SQLite 实现不支持这些 PRAGMA，
        // 启动优化不能阻断本地数据库打开。
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE catalog (id TEXT PRIMARY KEY, source TEXT NOT NULL, payload TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE details (id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE favorites (id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE history (id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_history_updated ON history(updated_at DESC)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_favorites_created ON favorites(created_at DESC)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_catalog_source ON catalog(source)',
          );
        },
        onOpen: (db) async {
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_history_updated ON history(updated_at DESC)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_favorites_created ON favorites(created_at DESC)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_catalog_source ON catalog(source)',
          );
        },
      ),
    );
    return SqliteAppStore._(db);
  }

  Map<String, dynamic> _payload(Map<String, Object?> row) =>
      jsonDecode(row['payload'] as String) as Map<String, dynamic>;

  @override
  Future<List<Drama>> readCatalog() async => (await _db.query(
    'catalog',
    orderBy: 'rowid',
  )).map((row) => Drama.fromJson(_payload(row))).toList();

  @override
  Future<void> saveCatalog(List<Drama> dramas) => _db.transaction((txn) async {
    final batch = txn.batch();
    for (final drama in dramas) {
      final row = {
        'id': drama.id,
        'source': drama.source,
        'payload': jsonEncode(drama.toJson()),
      };
      // INSERT OR IGNORE + UPDATE supports the SQLite bundled with Android 7.
      // It also preserves catalog order instead of replacing the row id.
      batch.insert('catalog', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      batch.update('catalog', row, where: 'id = ?', whereArgs: [drama.id]);
    }
    await batch.commit(noResult: true);
  });

  @override
  Future<DramaDetail?> readDetail(String dramaId) async {
    final rows = await _db.query(
      'details',
      where: 'id = ?',
      whereArgs: [dramaId],
    );
    if (rows.isEmpty) return null;
    return DramaDetail.fromJson(_payload(rows.first));
  }

  @override
  Future<void> saveDetail(DramaDetail detail) async {
    await _db.insert('details', {
      'id': detail.drama.id,
      'payload': jsonEncode(detail.toJson()),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<dynamic> _readSetting(String key) async {
    final rows = await _db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : jsonDecode(rows.first['value'] as String);
  }

  Future<void> _saveSetting(String key, dynamic value) async {
    await _db.insert('settings', {
      'key': key,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<Map<String, dynamic>?> readSourceState(String key) async =>
      (await _readSetting('source:$key')) as Map<String, dynamic>?;

  @override
  Future<Map<String, Map<String, dynamic>>> readSourceStatesByPrefix(
    String prefix,
  ) async {
    final rows = await _db.query(
      'settings',
      where: 'key LIKE ?',
      whereArgs: ['source:$prefix%'],
    );
    final results = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final key = (row['key'] as String).replaceFirst('source:', '');
      try {
        final decoded = jsonDecode(row['value'] as String);
        if (decoded is Map<String, dynamic>) {
          results[key] = decoded;
        }
      } catch (_) {}
    }
    return results;
  }

  @override
  Future<void> saveSourceState(String key, Map<String, dynamic> value) =>
      _saveSetting('source:$key', value);

  @override
  Future<void> saveCatalogPage(
    String key,
    List<Drama> dramas,
    CatalogCursor cursor,
    bool hasMore,
  ) => _db.transaction((txn) async {
    final batch = txn.batch();
    for (final drama in dramas) {
      final row = {
        'id': drama.id,
        'source': drama.source,
        'payload': jsonEncode(drama.toJson()),
      };
      batch.insert('catalog', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      batch.update('catalog', row, where: 'id = ?', whereArgs: [drama.id]);
    }
    batch.insert('settings', {
      'key': 'source:catalog:$key',
      'value': jsonEncode({'cursor': cursor.toJson(), 'hasMore': hasMore}),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  });

  @override
  Future<Preferences> readPreferences() async => Preferences.fromJson(
    (await _readSetting('preferences') as Map<String, dynamic>?) ?? {},
  );
  @override
  Future<void> savePreferences(Preferences preferences) =>
      _saveSetting('preferences', preferences.toJson());

  @override
  Future<List<Drama>> readFavorites() async => (await _db.query(
    'favorites',
    orderBy: 'created_at DESC',
  )).map((row) => Drama.fromJson(_payload(row))).toList();

  @override
  Future<void> setFavorite(Drama drama, bool favorite) async {
    if (favorite) {
      await _db.insert('favorites', {
        'id': drama.id,
        'payload': jsonEncode(drama.toJson()),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await _db.delete('favorites', where: 'id = ?', whereArgs: [drama.id]);
    }
  }

  @override
  Future<List<WatchRecord>> readHistory() async => (await _db.query(
    'history',
    orderBy: 'updated_at DESC',
    limit: 200,
  )).map((row) => WatchRecord.fromJson(_payload(row))).toList();

  @override
  Future<void> saveRecord(WatchRecord record) => _db.transaction((txn) async {
    await txn.insert('history', {
      'id': record.drama.id,
      'payload': jsonEncode(record.toJson()),
      'updated_at': record.updatedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await txn.rawDelete(
      'DELETE FROM history WHERE id NOT IN '
      '(SELECT id FROM history ORDER BY updated_at DESC LIMIT 200)',
    );
  });

  @override
  Future<void> deleteHistory(Iterable<String> dramaIds) =>
      _db.transaction((txn) async {
        final batch = txn.batch();
        for (final id in dramaIds) {
          batch.delete('history', where: 'id = ?', whereArgs: [id]);
        }
        await batch.commit(noResult: true);
      });

  @override
  Future<List<String>> readSearches() async =>
      (await _readSetting('searches') as List?)?.cast<String>() ?? [];
  @override
  Future<void> saveSearches(List<String> searches) =>
      _saveSetting('searches', searches);
  @override
  Future<DateTime?> readLastRefresh() async {
    final value = await _readSetting('lastRefresh') as int?;
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  @override
  Future<void> saveLastRefresh(DateTime time) =>
      _saveSetting('lastRefresh', time.millisecondsSinceEpoch);

  @override
  Future<int> cacheBytes() async {
    final rows = await _db.rawQuery(
      'SELECT '
      '(SELECT COALESCE(SUM(LENGTH(CAST(payload AS BLOB))), 0) FROM catalog) + '
      '(SELECT COALESCE(SUM(LENGTH(CAST(payload AS BLOB))), 0) FROM details) AS bytes',
    );
    return (rows.first['bytes'] as num).toInt();
  }

  @override
  Future<void> clearCache() => _db.transaction((txn) async {
    await txn.delete('catalog');
    await txn.delete('details');
    await txn.delete('settings', where: 'key = ?', whereArgs: ['lastRefresh']);
    await txn.delete(
      'settings',
      where: 'key LIKE ?',
      whereArgs: ['source:catalog:%'],
    );
  });
  @override
  Future<void> close() => _db.close();
}
