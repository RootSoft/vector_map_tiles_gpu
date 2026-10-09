import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../vector_map_tiles.dart';
import '../flutter_map/flutter_map_state.dart';
import '../flutter_map/flutter_map_zoom_scaler.dart';
import '../layout/tile_layout.dart';
import '../layout/tile_viewport_provider.dart';
import '../model/map_tiles.dart';
import '../tile_offset.dart';

typedef MapUpdatedCallback = void Function();

class FlutterMapAdapter {
  final tileSize = 256;
  StreamSubscription<MapEvent>? _subscription;
  final TileOffset tileOffset;
  final MapTiles mapTiles;
  final MapUpdatedCallback mapUpdated;
  double _zoom = 1.0;
  double _rotation = 0.0;

  FlutterMapAdapter({
    required this.tileOffset,
    required this.mapUpdated,
    required this.mapTiles,
  });

  double get zoom => _zoom;
  double get rotation => _rotation;

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  void update(BuildContext context) {
    final controller = MapController.maybeOf(context);
    if (controller != null) {
      _subscription ??= controller.mapEventStream.listen(_mapUpdated);
      // The camera flutter_map lays its layers out with. The controller's lags
      // it: until the map's first layout it still has flutter_map's impossible
      // (infinite) size, which made the tile bounds infinite and threw.
      final camera = MapCamera.maybeOf(context) ?? controller.camera;
      if (!_isUsable(camera)) return;
      final mapState = FlutterMapState(camera: camera);
      final viewportProvider = TileViewportProvider(
        mapState: mapState,
        tileOffset: tileOffset,
        tileSize: tileSize,
      );
      final viewport = viewportProvider.currentViewport();
      final bounds = viewport.bounds;
      if (!bounds.left.isFinite ||
          !bounds.top.isFinite ||
          !bounds.right.isFinite ||
          !bounds.bottom.isFinite) {
        return;
      }
      var layout = TileLayout(
        offset: tileOffset,
        viewport: viewport,
        tileSize: tileSize,
      );
      _zoom = camera.zoom;
      _rotation = camera.rotation;
      final zoomScaler = FlutterMapZoomScaler(crs: camera.crs)
        ..updateMapZoomScale(_zoom);
      final tilePositions = layout.computeTilePositions(mapState, zoomScaler);
      mapTiles.updateTiles(tilePositions);
      for (final model in mapTiles.obsoleteModels) {
        model.tilePosition = layout.positionTile(
          mapState,
          zoomScaler,
          model.tile,
        );
      }
    }
  }

  void _mapUpdated(MapEvent event) => mapUpdated();

  /// Whether [camera] describes a laid-out view tiles can be computed for: a
  /// finite, non-empty size and a finite zoom and centre.
  static bool _isUsable(MapCamera camera) {
    final size = camera.nonRotatedSize;
    return size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0 &&
        camera.zoom.isFinite &&
        camera.center.latitude.isFinite &&
        camera.center.longitude.isFinite;
  }
}
