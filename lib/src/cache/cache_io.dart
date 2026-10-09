import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
// ignore: implementation_imports
import 'package:stash/src/api/cache/stats/default_stats.dart';
import 'package:stash/stash_api.dart';
import 'package:vector_map_tiles/src/cache/byte_storage.dart';
import 'package:vector_map_tiles/src/cache/byte_storage_io.dart';

import 'abstract_stash_cache.dart';
import 'cache.dart';

class CacheIo extends AbstractStashCache {
  CacheIo({required CacheProperties properties})
    : super(name: 'io', cacheFactory: () => createStashIoCache(properties));
}

Future<BinaryCache> createStashIoCache(CacheProperties properties) async {
  final pather = properties.cacheFolder ?? cacheStorageResolver;
  return _ByteStorageBinaryCache(
    storage: IoByteStorage(pather: pather),
    ttl: properties.fileCacheTtl,
    maxSizeInBytes: properties.fileCacheMaximumSizeInBytes,
  );
}

Future<Directory> cacheStorageResolver() async {
  final tempFolder = await getTemporaryDirectory();
  return Directory('${tempFolder.path}/.vector_map');
}

class _ByteStorageBinaryCache extends BinaryCache {
  final ByteStorage storage;
  int _putCount = 0;
  final Duration ttl;
  final int maxSizeInBytes;
  @override
  final stats = DefaultCacheStats();

  _ByteStorageBinaryCache({
    required this.storage,
    required this.ttl,
    required this.maxSizeInBytes,
  });

  @override
  Future<Uint8List?> operator [](String key) => get(key);

  @override
  Future<void> clear() async {
    final entries = await storage.list();
    for (final entry in entries) {
      try {
        await storage.delete(entry.path);
      } catch (e) {
        // ignore
      }
    }
    stats.clear();
  }

  @override
  Future<void> close() async {
    // nothing to do
  }

  @override
  Future<bool> containsKey(String key) async => await storage.exists(key);

  @override
  Future<Uint8List?> get(
    String key, {
    CacheEntryDelegate<Uint8List>? delegate,
  }) async {
    final v = await storage.read(key);
    stats.increaseGets();
    if (v == null) {
      stats.increaseMisses();
    }
    return v;
  }

  @override
  Future<Uint8List?> getAndPut(
    String key,
    Uint8List value, {
    CacheEntryDelegate<Uint8List>? delegate,
  }) async {
    await storage.write(key, value);
    return null;
  }

  @override
  Future<Uint8List?> getAndRemove(String key) async {
    final v = await get(key);
    if (v != null) {
      await remove(key);
    }
    return v;
  }

  @override
  Future<Iterable<String>> get keys async {
    final entries = await storage.list();
    return entries.map((e) => e.path);
  }

  @override
  CacheManager? get manager => null;

  @override
  String get name => 'byte_storage';

  @override
  Stream<E> on<E extends CacheEvent<Uint8List>>() => Stream.empty();

  @override
  Future<void> put(
    String key,
    Uint8List value, {
    CacheEntryDelegate<Uint8List>? delegate,
  }) async {
    if (++_putCount % 20 == 0) _scheduleMaxSize();
    await storage.write(key, value);
  }

  @override
  Future<bool> putIfAbsent(
    String key,
    Uint8List value, {
    CacheEntryDelegate<Uint8List>? delegate,
  }) async {
    await put(key, value, delegate: delegate);
    return true;
  }

  @override
  Future<void> remove(String key) async {
    await storage.delete(key);
  }

  @override
  Future<int> get size async {
    final entries = await storage.list();
    return entries.length;
  }

  @override
  bool get statsEnabled => true;

  Future<void> applyConstraints() async {
    try {
      await _applyMaxAge();
      await _applyMaxSize();
    } catch (e) {
      // ignore, race condition directory may have been deleted
    }
  }

  Future<void> _applyMaxAge() async {
    final entries = await storage.list();
    for (final entry in entries) {
      await _expireIfExceedsTtl(entry);
    }
  }

  Future<void> _applyMaxSize() => storage.enforceMaxSize(maxSizeInBytes);

  /// Keeps the cache within [maxSizeInBytes] without holding up the put that
  /// triggered it: at most every [_maxSizeInterval], never twice at once.
  void _scheduleMaxSize() {
    final now = DateTime.now();
    final last = _lastMaxSize;
    if (_applyingMaxSize ||
        (last != null && now.difference(last) < _maxSizeInterval)) {
      return;
    }
    _applyingMaxSize = true;
    _lastMaxSize = now;
    _applyMaxSize().catchError((_) {}).whenComplete(() {
      _applyingMaxSize = false;
    });
  }

  static const _maxSizeInterval = Duration(seconds: 30);
  bool _applyingMaxSize = false;
  DateTime? _lastMaxSize;

  Future<void> _expireIfExceedsTtl(ByteStorageEntry entity) async {
    final exceeds = _exceedsTtl(entity);
    if (exceeds) {
      await storage.delete(entity.path);
      stats.increaseEvictions();
    }
  }

  bool _exceedsTtl(ByteStorageEntry entry) {
    final now = DateTime.now();
    final age =
        now.millisecondsSinceEpoch - entry.modified.millisecondsSinceEpoch;
    return (age >= ttl.inMilliseconds);
  }
}
