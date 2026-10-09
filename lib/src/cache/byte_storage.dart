import 'dart:typed_data';

abstract class ByteStorage {
  Future<void> write(String path, Uint8List bytes);
  Future<Uint8List?> read(String path);
  Future<void> delete(String path);
  Future<bool> exists(String key);
  Future<List<ByteStorageEntry>> list();

  /// Deletes the least recently accessed entries until the stored bytes are
  /// at most [maxSizeInBytes].
  Future<void> enforceMaxSize(int maxSizeInBytes) async {
    final entries = await list();
    var size = entries.fold(0, (total, entry) => total + entry.size);
    if (size <= maxSizeInBytes) return;
    entries.sort((a, b) => a.accessed.compareTo(b.accessed));
    for (final entry in entries) {
      try {
        await delete(entry.path);
        size -= entry.size;
        if (size <= maxSizeInBytes) return;
      } catch (_) {
        // Deleted meanwhile.
      }
    }
  }
}

class ByteStorageEntry {
  final String path;
  final int size;
  final DateTime modified;
  final DateTime accessed;

  ByteStorageEntry({
    required this.path,
    required this.size,
    required this.modified,
    required this.accessed,
  });
}
