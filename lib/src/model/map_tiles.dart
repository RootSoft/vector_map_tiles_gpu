import 'dart:async';
import 'dart:math';

import 'package:executor_lib/executor_lib.dart';

import '../../vector_map_tiles.dart';
import '../layout/tile_position.dart';
import '../loader/tile_loader.dart';
import 'safe_change_notifier.dart';
import 'tile_data_model.dart';

class MapTiles extends SafeChangeNotifier {
  final _tiles = <TileIdentity, TileDataModel>{};
  final _jobs = <TileIdentity, _TileJob>{};
  final _retries = <TileIdentity, Timer>{};
  List<TileIdentity> _latestTileIds = [];

  List<TileDataModel> get tileModels =>
      _tiles.values.toList()..sort(_zOrderSort);

  List<TileDataModel> get obsoleteModels => _latestTileIds.isEmpty
      ? []
      : _tiles.values
            .where((it) => _latestTileIds.first.z != it.tile.z)
            .toList();

  final TileLoader tileLoader;

  MapTiles({required this.tileLoader});

  void updateTiles(Iterable<TilePosition> neededTiles) {
    if (isDisposed) {
      return;
    }
    final originalTilePositions = _tiles.values
        .map((e) => e.tilePosition)
        .toSet();
    _latestTileIds = neededTiles.map((e) => e.tile).toList(growable: false);
    final idToTilePosition = Map.fromEntries(
      neededTiles.map((e) => MapEntry(e.tile, e)),
    );
    final newTiles = <TileDataModel>[];
    for (final tilePosition in idToTilePosition.values) {
      var model = _tiles[tilePosition.tile];
      if (model == null) {
        model = TileDataModel(tilePosition);
        _tiles[tilePosition.tile] = model;
        newTiles.add(model);
      } else {
        model.tilePosition = tilePosition;
      }
    }
    bool removedSome = _removeObsoleteTiles();
    for (var model in newTiles) {
      _startLoading(model);
    }
    final newTilePositions = _tiles.values.map((e) => e.tilePosition).toSet();
    if (removedSome || !_equals(newTilePositions, originalTilePositions)) {
      notifyListeners();
    }
  }

  List<TileDataModel> _computeTilesToRemove() {
    final neededTileIds = _latestTileIds.toSet();
    final loadingTileModels = _tiles.values
        .where((it) => !it.isDisplayReady)
        .toList();
    final obsoleteModels = _tiles.values
        .where((model) => !neededTileIds.contains(model.tile))
        .toList();
    if (loadingTileModels.isEmpty || neededTileIds.isEmpty) {
      return obsoleteModels;
    }
    final zoom = neededTileIds.first.z;
    const maxZoomDifference = 5;
    final toRetain = obsoleteModels
        .where(
          (it) =>
              it.isDisplayReady &&
              (it.tile.z - zoom).abs() <= maxZoomDifference &&
              it.tile.z != zoom &&
              loadingTileModels.any(
                (loadingTile) => loadingTile.tile.overlaps(it.tile),
              ),
        )
        .toList();
    final toRetainIds = toRetain.map((it) => it.tile).toSet();
    return obsoleteModels
        .where((it) => !toRetainIds.contains(it.tile))
        .toList();
  }

  void _startLoading(TileDataModel model, {int attempt = 0}) {
    final job = _TileJob(model, attempt);
    _jobs[model.tile] = job;
    _start(job);
  }

  @override
  void dispose() {
    if (!isDisposed) {
      super.dispose();
      _remove(_tiles.values.toList());
      _jobs.clear();
      for (final retry in _retries.values) {
        retry.cancel();
      }
      _retries.clear();
      _tiles.clear();
    }
  }

  bool _equals(Set<TilePosition> a, Set<TilePosition> b) =>
      a.containsAll(b) && b.containsAll(a);

  void _start(_TileJob job) async {
    try {
      await tileLoader.load(job.model, () => job.cancelled);
    } on CancellationException catch (_) {
      // By identity: panned away and back, the tile has a new model and job
      // by now, which this late cancellation must not take with it.
      if (identical(_tiles[job.model.tile], job.model)) {
        _tiles.remove(job.model.tile);
      }
      job.model.dispose();
    } catch (error) {
      _scheduleRetry(job, error);
    } finally {
      if (identical(_jobs[job.model.tile], job)) {
        _jobs.remove(job.model.tile);
      }
      _removeObsoleteTiles();
      notifyListeners();
    }
  }

  /// Loads a tile that failed again after a backoff (1 s doubling to 30 s), for
  /// as long as it stays in view, unless the provider says asking again
  /// cannot help.
  ///
  /// A provider failure (a network error, the connection briefly read as
  /// offline) otherwise left the tile unloaded for as long as it was in view:
  /// nothing asked for it again until it was panned away and back. The model
  /// stays in place meanwhile, so the tiles of other zooms covering it are
  /// retained and the area is not left blank.
  void _scheduleRetry(_TileJob job, Object error) {
    final model = job.model;
    if (job.cancelled || isDisposed) return;
    if (error is ProviderException) {
      // A provider that says retry is asked for as long as the tile is in
      // view: a connection back after minutes must still fill it in.
      if (error.retryable == Retryable.none) return;
    } else if (job.attempt >= _maxOtherRetries) {
      // Anything else (a tile that does not decode) is unlikely to change.
      return;
    }
    final delay = Duration(seconds: min(30, 1 << min(job.attempt, 5)));
    _retries.remove(model.tile)?.cancel();
    _retries[model.tile] = Timer(delay, () {
      _retries.remove(model.tile);
      if (isDisposed || !identical(_tiles[model.tile], model)) return;
      if (model.isLoaded || _jobs.containsKey(model.tile)) return;
      _startLoading(model, attempt: job.attempt + 1);
    });
  }

  static const _maxOtherRetries = 3;

  bool _removeObsoleteTiles() {
    final toRemove = _computeTilesToRemove();
    _remove(toRemove);
    return toRemove.isNotEmpty;
  }

  void _remove(List<TileDataModel> toRemove) {
    for (var model in toRemove) {
      _jobs.remove(model.tile)?.cancel();
      _retries.remove(model.tile)?.cancel();
      _tiles.remove(model.tile);
      model.dispose();
    }
  }
}

class _TileJob {
  bool cancelled = false;
  final TileDataModel model;
  final int attempt;
  _TileJob(this.model, this.attempt);

  void cancel() {
    cancelled = true;
  }
}

int _zOrderSort(TileDataModel a, TileDataModel b) {
  var i = a.tile.z.compareTo(b.tile.z);
  if (i == 0) {
    i = a.tile.x.compareTo(b.tile.x);
    if (i == 0) {
      i = a.tile.y.compareTo(b.tile.y);
    }
  }
  return i;
}
