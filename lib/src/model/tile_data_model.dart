import 'dart:typed_data';

import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../layout/tile_position.dart';
import '../loader/vector_tile_loader.dart';
import '../tile_identity.dart';

class TileDataModel {
  late final TileIdentity tile;
  TilePosition tilePosition;
  bool isLoaded = false;
  bool isDisplayReady = false;

  /// Whether the renderer has built the tile and draws it. A tile can be ready
  /// a few frames before it is drawn: the renderer builds new tiles within a
  /// budget per frame.
  bool isDrawn = false;
  bool preRenderStarted = false;
  int preRenderFailures = 0;
  Tileset? tileset;

  /// The bytes the [tileset]'s source tiles were read from, for the pre-render
  /// job to read again; dropped once it has run.
  Map<String, SourceTileBytes>? sourceBytes;
  RasterTileset? rasterTileset;

  /// The tile's pre-rendered GPU data, one map of layer id to packed render
  /// data per pre-render pass (text, then each source tile's early pass).
  List<Map<String, Uint8List>>? renderData;

  TileDataModel(this.tilePosition) : tile = tilePosition.tile;

  void dispose() {
    isLoaded = false;
    isDisplayReady = false;
    isDrawn = false;
    preRenderStarted = false;
    rasterTileset?.dispose();
    rasterTileset = null;
    tileset = null;
    sourceBytes = null;
    renderData = null;
  }
}
