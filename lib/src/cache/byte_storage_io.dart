import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'byte_storage.dart';

typedef PathFunction = Future<Directory> Function();

class IoByteStorage extends ByteStorage {
  final PathFunction _pather;
  String? _path;

  IoByteStorage._withPath(this._pather);

  IoByteStorage({required PathFunction pather}) : this._withPath(pather);

  Future<String> get _storagePath async {
    String? path = _path;
    if (path == null) {
      final directory = await _pather();
      final exists = await directory.exists();
      if (!exists) {
        await directory.create(recursive: true);
      }
      path = directory.path;
      _path = path;
    }
    return path;
  }

  Future<File> fileOf(String path) async {
    final root = await _storagePath;
    return File("$root/$path");
  }

  Future<Directory> storageDirectory() async {
    final root = await _storagePath;
    return Directory(root);
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final file = await fileOf(path);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsBytes(bytes);
  }

  @override
  Future<Uint8List?> read(String path) async {
    final file = await fileOf(path);
    if (await file.exists()) {
      return file.readAsBytes();
    }
    return null;
  }

  @override
  Future<void> delete(String path) async {
    final file = await fileOf(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<bool> exists(String key) async {
    final file = await fileOf(key);
    return file.exists();
  }

  @override
  Future<List<ByteStorageEntry>> list() async {
    final directory = await storageDirectory();
    if (await directory.exists()) {
      return await directory
          .list()
          .asyncMap(_toEntry)
          .where((e) => e.value.type == FileSystemEntityType.file)
          .map(
            (f) => ByteStorageEntry(
              path: f.key.path.split(RegExp(r'/|\\')).last,
              size: f.value.size,
              modified: f.value.modified,
              accessed: f.value.accessed,
            ),
          )
          .toList();
    }
    return [];
  }

  /// Runs on a background isolate with synchronous file calls. On the UI
  /// isolate this listed the cache and read every file's size one awaited
  /// call at a time: thousands of file operations whenever the check ran,
  /// which held up frames and, on a full cache, the UI for long enough to
  /// trigger an ANR on Android.
  @override
  Future<void> enforceMaxSize(int maxSizeInBytes) async {
    final root = await _storagePath;
    await Isolate.run(() => _enforceMaxSizeSync(root, maxSizeInBytes));
  }

  static void _enforceMaxSizeSync(String root, int maxSizeInBytes) {
    final directory = Directory(root);
    if (!directory.existsSync()) return;
    final files = <(File, FileStat)>[];
    var size = 0;
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final stat = entity.statSync();
      if (stat.type != FileSystemEntityType.file) continue;
      files.add((entity, stat));
      size += stat.size;
    }
    if (size <= maxSizeInBytes) return;
    files.sort((a, b) => a.$2.accessed.compareTo(b.$2.accessed));
    for (final (file, stat) in files) {
      try {
        file.deleteSync();
        size -= stat.size;
        if (size <= maxSizeInBytes) return;
      } catch (_) {
        // Deleted meanwhile.
      }
    }
  }

  Future<MapEntry<FileSystemEntity, FileStat>> _toEntry(
    FileSystemEntity entity,
  ) async {
    return MapEntry(entity, await entity.stat());
  }
}
