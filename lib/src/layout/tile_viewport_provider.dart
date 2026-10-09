import 'dart:math';
import 'dart:ui';

import '../../vector_map_tiles.dart';
import 'map_state.dart';
import 'tile_viewport.dart';
import 'zoom_scaler.dart';

class TileViewportProvider {
  final MapState mapState;
  final TileOffset tileOffset;
  final int tileSize;

  TileViewportProvider({
    required this.mapState,
    required this.tileOffset,
    required this.tileSize,
  });

  TileViewport currentViewport() {
    final pixelBounds = _tiledPixelBounds();
    final topLeft = Offset(
      (pixelBounds.left / tileSize).floorToDouble(),
      (pixelBounds.top / tileSize).floorToDouble(),
    );
    final bottomRight = Offset(
      (pixelBounds.right / tileSize).ceilToDouble() - 1,
      (pixelBounds.bottom / tileSize).ceilToDouble() - 1,
    );
    final tileRect = Rect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      bottomRight.dx,
      bottomRight.dy,
    );
    double clampedTileZoom = _clampedTileZoom();
    return TileViewport(zoom: clampedTileZoom.toInt(), bounds: tileRect);
  }

  double tileZoom() => max(1.0, (mapState.zoom + tileOffset.zoomOffset));

  /// The tile zoom, at most the deepest zoom [ZoomScaler] has a scale for (it
  /// threw a RangeError on a map zoomed in past it). Deeper map zooms draw
  /// these tiles scaled up.
  double _clampedTileZoom() =>
      min(tileZoom().floorToDouble(), maxTileZoom.toDouble());

  static const maxTileZoom = ZoomScaler.defaultMaxZoom - 1;

  Rect _tiledPixelBounds() {
    final zoom = mapState.zoom;
    final clampedTileZoom = _clampedTileZoom();
    final scale = mapState.getZoomScale(zoom, clampedTileZoom);
    final center = mapState.projectAtZoom(
      mapState.center,
      clampedTileZoom,
    ); // Offset
    final halfSize = mapState.size / (scale * 2); // Size

    final halfSizeOffset = Offset(halfSize.width, halfSize.height);
    final topLeft = center - halfSizeOffset;
    final bottomRight = center + halfSizeOffset;

    return Rect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      bottomRight.dx,
      bottomRight.dy,
    );
  }
}
