import 'dart:async';

import 'package:vector_map_tiles/src/loader/tile_loader.dart';
import 'package:vector_map_tiles/src/model/tile_data_model.dart';

class MockTileLoader implements TileLoader {
  final Map<String, Completer<void>> _completers = {};
  final Map<String, bool> _shouldComplete = {};

  /// Whether ready tiles count as drawn too, as the layer and renderer mark
  /// them; false holds them at ready but not yet built.
  bool _drawn = true;
  set drawsReadyTiles(bool value) => _drawn = value;

  @override
  Future<void> load(TileDataModel model, bool Function() cancelled) async {
    final key = model.tile.key();
    final completer = Completer<void>();
    _completers[key] = completer;

    if (_shouldComplete[key] == true) {
      model.isDisplayReady = true;
      model.isDrawn = _drawn;
      completer.complete();
    }

    await completer.future;
    if (!cancelled()) {
      model.isDisplayReady = true;
      model.isDrawn = _drawn;
    }
  }

  void completeTile(String tileKey) {
    _shouldComplete[tileKey] = true;
    final completer = _completers[tileKey];
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void markTileAsReady(String tileKey) {
    _shouldComplete[tileKey] = true;
  }

  bool isLoading(String tileKey) {
    final completer = _completers[tileKey];
    return completer != null && !completer.isCompleted;
  }

  void reset() {
    _completers.clear();
    _shouldComplete.clear();
  }
}
