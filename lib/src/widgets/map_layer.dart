import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../vector_map_tiles.dart';
import '../loader/caching_tile_loader.dart';
import '../loader/theme_repo.dart';
import '../loader/vector_tile_transform.dart';
import '../model/map_properties.dart';
import '../model/tile_data_model.dart';
import '../tile_translation.dart';
import 'abstract_map_layer_state.dart';

class MapLayer extends AbstractMapLayer {
  const MapLayer({super.key, required super.mapProperties})
    : super(tileLoaderFactory: createCachingTileLoader);

  @override
  State<StatefulWidget> createState() => MapLayerState();
}

class MapLayerState extends AbstractMapLayerState<MapLayer> {
  // Not final: a new theme brings a new renderer (didUpdateWidget).
  late TilesRenderer tilesRenderer;
  var _ready = false;
  ui.Image? _spriteAtlas;
  List<String> _previousTileKeys = [];
  var _buildScheduled = false;

  @override
  void initState() {
    super.initState();
    tilesRenderer = TilesRenderer(widget.mapProperties.theme);
    TilesRenderer.initialize.then(_initialized, onError: _initializationFailed);
    _loadSprites();
  }

  @override
  void dispose() {
    super.dispose();
    tilesRenderer.dispose();
    _spriteAtlas?.dispose();
  }

  /// Decodes the theme's sprite sheet once, for the renderer to draw sprite
  /// icons from. Without it (no sprites, or a sheet that fails to load) the map
  /// is drawn without them rather than not at all.
  Future<void> _loadSprites() async {
    final sprites = widget.mapProperties.sprites;
    if (sprites == null) return;
    try {
      final codec = await ui.instantiateImageCodec(
        await sprites.atlasProvider(),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted || widget.mapProperties.sprites != sprites) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _spriteAtlas?.dispose();
        _spriteAtlas = frame.image;
      });
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant MapLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mapProperties.theme != widget.mapProperties.theme) {
      tilesRenderer.dispose();
      tilesRenderer = TilesRenderer(widget.mapProperties.theme);
      super.resetState();
    }
    if (oldWidget.mapProperties.sprites != widget.mapProperties.sprites) {
      _loadSprites();
    }
  }

  @override
  Future<void> preRender(TileDataModel tile) {
    return super.preRender(tile).then((_) async {
      final tileset = tile.tileset ?? Tileset({});
      final tileID = tile.tile.key();

      // Text atlases are built here, on the UI isolate, before the job that
      // lays the text out against them.
      await tilesRenderer.preRenderUi(zoom, tileset, tileID);

      // The job is copied to the worker by this isolate. A parsed tileset is
      // thousands of small objects, so it is sent the bytes its source tiles
      // were read from instead, and reads them again there.
      final sourceBytes = tile.sourceBytes;
      final jobArguments = (
        widget.mapProperties.theme.id,
        zoom,
        sourceBytes == null ? tileset : null,
        widget.mapProperties.tileOffset.zoomOffset,
        sourceBytes == null
            ? null
            : {
                for (final MapEntry(:key, :value) in sourceBytes.entries)
                  key: (
                    TransferableTypedData.fromList([value.bytes]),
                    value.translation,
                    value.tileSize,
                  ),
              },
      );
      await executor
          .submit(
            Job(
              "pre-render",
              _preRenderJob(
                tilesRenderer.getTilePreRenderer(tileID),
                ThemeLayerType.values
                    .where(tilesRenderer.isPreRenderLayer)
                    .toSet(),
              ),
              jobArguments,
              // A tile removed meanwhile (panned away) is not worth the work.
              cancelled: () => !tile.isLoaded,
              deduplicationKey:
                  "pre-render:${widget.mapProperties.theme.id}-${widget.mapProperties.theme.version}-$zoom-${tile.tile.key()}",
            ),
          )
          .then((renderData) {
            try {
              tile.renderData ??= renderData;
              // Everything the GPU draws is in the render data now. The parsed
              // tileset (often over 10 MB a tile) held on would keep the Dart
              // heap at hundreds of MB with tiles parked (see MapTiles), and
              // its collections stalled frames.
              tile.sourceBytes = null;
              tile.tileset = null;
            } catch (_) {}
          });
    });
  }

  /// The pre-render job: the text layers through the renderer's pre-renderer,
  /// then each source tile's early pass (polygons, lines and the rest), the
  /// two halves `TileUiModel.renderData` takes since vector_tile_renderer
  /// 7.0.0-beta.2, batched into one pass of merged fills and lines. The
  /// tileset comes either as is or as its source tiles' bytes, read here.
  ///
  /// Static on purpose: the job is sent to a worker isolate, and a closure made
  /// in an instance method shares its captured context with every other
  /// closure there. One that reads a field captures `this`, the whole widget
  /// state and render tree, which cannot be sent ("object is unsendable").
  static List<Map<String, Uint8List>> Function(_PreRenderArguments args)
  _preRenderJob(
    Map<String, Uint8List> Function(Theme, double, Tileset, int) preRenderer,
    Set<ThemeLayerType> preRenderTypes,
  ) {
    return (_PreRenderArguments args) {
      final (themeId, zoom, sentTileset, zoomOffset, sources) = args;
      final theme = ThemeRepo.themeById[themeId]!;
      final tileset =
          sentTileset ??
          Tileset({
            for (final MapEntry(key: source, value: (bytes, translation, size))
                in sources!.entries)
              source: parseSourceTile(
                themeId: themeId,
                bytes: bytes.materialize().asUint8List(),
                translation: translation,
                tileSize: size,
              ),
          });
      final text = preRenderer.call(
        theme.copyWith(types: preRenderTypes),
        zoom,
        tileset,
        zoomOffset,
      );
      final early = [
        for (final MapEntry(key: source, value: sourceTile)
            in tileset.tiles.entries)
          (sourceTile..earlyPreRender(theme, zoom, zoomOffset, source))
              .materialize()
              .prerenderData,
      ];
      // Merged into as few draws as the paint order allows, here rather than
      // on the UI isolate.
      return TilesRenderer.batchRenderData(theme, [text, ...early]);
    };
  }

  @override
  Widget build(BuildContext context) {
    updateTiles(context);
    if (!_ready) {
      return Container();
    }
    final tileModels = mapTiles.tileModels
        .where((it) => it.isDisplayReady)
        .toList(growable: false);
    final uiTiles = tileModels
        .map(
          (it) => it.toUiModel(
            spriteIndex: widget.mapProperties.sprites?.index,
            spriteAtlas: _spriteAtlas,
          ),
        )
        .toList(growable: false);

    final currentTileKeys = uiTiles.map((it) => it.tileId.key()).toList();
    if (!_tilesEqual(currentTileKeys, _previousTileKeys)) {
      _previousTileKeys = currentTileKeys;
      onTilesChanged();
    }

    tilesRenderer.update(
      zoom,
      uiTiles,
      mapTiles.tileModels.map((it) => it.tile.key()),
    );
    for (final model in tileModels) {
      model.isDrawn = tilesRenderer.isBuilt(model.tile.key());
    }
    // Tiles left for a later frame: build again then. The update after the
    // last of them lets the tiles they replace go.
    if (tilesRenderer.hasPendingTiles && !_buildScheduled) {
      _buildScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _buildScheduled = false;
        if (mounted) setState(() {});
      });
    }

    return CustomPaint(
      key: Key(
        'mapTileLayer_${widget.mapProperties.theme.id}_${widget.mapProperties.theme.version}',
      ),
      painter: MapTilesPainter(widget.mapProperties, tilesRenderer, rotation),
      isComplex: true,
    );
  }

  bool _tilesEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final setA = a.toSet();
    final setB = b.toSet();
    return setA.length == setB.length && setA.containsAll(setB);
  }

  /// Flutter GPU is unavailable (no Impeller, or a test run): the layer stays
  /// empty rather than throwing while the map is built.
  void _initializationFailed(Object error, StackTrace stackTrace) {
    debugPrint(
      'vector_map_tiles: GPU rendering is unavailable, so the vector '
      'layer is not drawn: $error',
    );
  }

  FutureOr _initialized(void value) {
    if (mounted) {
      setState(() {
        _ready = true;
      });
    }
  }
}

/// Theme id, zoom, the tileset (or null when sent as source bytes), zoom
/// offset, and the source tiles' bytes, translations and tile size.
typedef _PreRenderArguments = (
  String,
  double,
  Tileset?,
  int,
  Map<String, (TransferableTypedData, TileTranslation, double)>?,
);

class MapTilesPainter extends CustomPainter {
  final MapProperties properties;
  final TilesRenderer tilesRenderer;
  final double rotation;

  MapTilesPainter(this.properties, this.tilesRenderer, this.rotation)
    : super(repaint: tilesRenderer.repaint);

  @override
  void paint(Canvas canvas, Size size) {
    tilesRenderer.render(canvas, size, rotation);
  }

  @override
  bool shouldRepaint(covariant MapTilesPainter oldDelegate) => true;
}

extension _TileDataModelUiExtension on TileDataModel {
  TileUiModel toUiModel({SpriteIndex? spriteIndex, ui.Image? spriteAtlas}) =>
      TileUiModel(
        tileId: tile.toTileId(),
        position: tilePosition.position,
        tileSource: TileSource(
          tileset: tileset ?? Tileset({}),
          rasterTileset: rasterTileset ?? const RasterTileset(tiles: {}),
          // Both or neither: an index without its sheet has nothing to draw.
          spriteIndex: spriteAtlas == null ? null : spriteIndex,
          spriteAtlas: spriteAtlas,
        ),
        renderData: renderData,
      );
}

extension _TileIdExtension on TileIdentity {
  TileId toTileId() => TileId(z: z, x: x, y: y);
}
