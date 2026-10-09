import 'dart:typed_data';

import 'package:executor_lib/executor_lib.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../vector_map_tiles.dart';
import '../cache/cache.dart';
import '../model/map_properties.dart';
import '../tile_translation.dart';
import 'theme_repo.dart';
import 'vector_tile_transform.dart';

class VectorTileLoader {
  final double tileSize;
  final MapProperties mapProperties;
  final Cache cache;
  late final VectorTileTransform transform;
  final Executor executor;
  final ThemeRepo themeRepo;

  VectorTileLoader({
    required this.tileSize,
    required this.mapProperties,
    required this.executor,
    required this.cache,
    required this.themeRepo,
  }) {
    transform = VectorTileTransform(
      executor: executor,
      theme: mapProperties.theme,
      tileSize: tileSize,
      themeRepo: themeRepo,
    );
  }

  Future<Tileset> load(TileIdentity tile, bool Function() cancelled) async =>
      (await loadWithSources(tile, cancelled)).$1;

  /// The tileset, and the bytes each of its source tiles was read from (see
  /// [SourceTileBytes]).
  Future<(Tileset, Map<String, SourceTileBytes>)> loadWithSources(
    TileIdentity tile,
    bool Function() cancelled,
  ) async {
    final sourceTiles = mapProperties.theme.tileSources
        .map(
          (source) => MapEntry(source, mapProperties.tileProviders.get(source)),
        )
        .where((e) => e.value.type == TileProviderType.vector)
        .map((e) => _load(e.key, e.value, tile, cancelled));
    final tilesBySource = <String, Tile>{};
    final bytesBySource = <String, SourceTileBytes>{};
    for (final sourceTileFuture in sourceTiles) {
      final sourceTile = await sourceTileFuture;
      final tile = sourceTile.tile;
      if (tile != null) {
        tilesBySource[sourceTile.source] = tile;
      }
      final bytes = sourceTile.bytes;
      if (bytes != null) {
        bytesBySource[sourceTile.source] = bytes;
      }
    }
    return (Tileset(tilesBySource), bytesBySource);
  }

  TileData _emptyTile() => TileFactory(
    mapProperties.theme,
    const Logger.noop(),
  ).createTileData(VectorTile(layers: []));

  Future<_SourceTile> _load(
    String source,
    VectorTileProvider provider,
    TileIdentity tile,
    bool Function() cancelled,
  ) async {
    if (tile.z < provider.minimumZoom) {
      return _SourceTile(source: source, tile: _emptyTile().toTile());
    }
    var translation = SlippyMapTranslator(provider.maximumZoom).translate(tile);
    final tileToLoad = translation.translated;
    final themeKey = mapProperties.theme.id;
    final cacheKey =
        '${themeKey}_${source}_${tileToLoad.z}_${tileToLoad.x}_${tileToLoad.y}.pbf';
    final Uint8List bytes;
    try {
      bytes = await cache.get(
        cacheKey,
        load: (key) => provider.provide(tileToLoad),
      );
    } on ProviderException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 204) {
        return _SourceTile(source: source, tile: _emptyTile().toTile());
      }
      rethrow;
    }
    if (cancelled()) {
      throw CancellationException();
    }
    final transformed = await transform.apply(bytes, translation, cancelled);
    return _SourceTile(
      source: source,
      tile: transformed,
      bytes: SourceTileBytes(
        bytes: bytes,
        translation: translation,
        tileSize: tileSize,
      ),
    );
  }
}

/// What a source tile was read from: enough to read it again on another
/// isolate (see [parseSourceTile]).
class SourceTileBytes {
  final Uint8List bytes;
  final TileTranslation translation;
  final double tileSize;

  SourceTileBytes({
    required this.bytes,
    required this.translation,
    required this.tileSize,
  });
}

class _SourceTile {
  final String source;
  final Tile? tile;
  final SourceTileBytes? bytes;

  _SourceTile({required this.source, required this.tile, this.bytes});
}
