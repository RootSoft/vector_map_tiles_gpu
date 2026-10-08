import 'dart:async';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../executors/shared_executor.dart';
import '../loader/theme_repo.dart';
import '../loader/tile_loader.dart';
import '../model/map_properties.dart';
import '../model/map_tiles.dart';
import '../model/tile_data_model.dart';
import 'flutter_map_adapter.dart';

abstract class AbstractMapLayer extends StatefulWidget {
  final MapProperties mapProperties;
  final TileLoader Function(MapProperties, Executor, ThemeRepo)
  tileLoaderFactory;

  const AbstractMapLayer({
    super.key,
    required this.mapProperties,
    required this.tileLoaderFactory,
  });
}

abstract class AbstractMapLayerState<T extends AbstractMapLayer>
    extends State<T>
    with SingleTickerProviderStateMixin {
  late final Executor executor;
  late final TileLoader tileLoader;
  late final MapTiles mapTiles;
  FlutterMapAdapter? _mapAdapter;
  Ticker? _animationTicker;
  DateTime? _animationEndTime;

  @override
  void dispose() {
    _animationTicker?.dispose();
    releaseSharedExecutor();
    _mapAdapter?.dispose();
    super.dispose();
  }

  double get zoom => _mapAdapter?.zoom ?? 1.0;
  double get rotation => _mapAdapter?.rotation ?? 0.0;

  void updateTiles(BuildContext context) {
    _updateTiles();
    _mapAdapter?.update(context);
  }

  void _updateTiles() {
    for (final tile in mapTiles.tileModels.where(
      (model) =>
          model.isLoaded && !model.isDisplayReady && !model.preRenderStarted,
    )) {
      preRender(tile).then((_) {
        if (mounted) {
          setState(() {
            tile.isDisplayReady = tile.isLoaded;
          });
        }
      }, onError: (Object _) => _preRenderFailed(tile));
    }
  }

  /// A tile whose pre-render failed is pre-rendered again on a later build, a
  /// few times, rather than left blank for as long as it is in view. A tile
  /// removed meanwhile (its job cancelled) is simply dropped.
  void _preRenderFailed(TileDataModel tile) {
    if (!tile.isLoaded || ++tile.preRenderFailures > _maxPreRenderAttempts) {
      return;
    }
    Future.delayed(Duration(milliseconds: 500 * tile.preRenderFailures), () {
      if (!mounted || !tile.isLoaded) return;
      tile.preRenderStarted = false;
      _updateTiles();
    });
  }

  static const _maxPreRenderAttempts = 3;

  void onTilesChanged() {
    _startAnimationPeriod();
  }

  void _startAnimationPeriod() {
    final now = DateTime.now();
    final endTime = now.add(const Duration(milliseconds: 1000));

    if (_animationEndTime == null || endTime.isAfter(_animationEndTime!)) {
      _animationEndTime = endTime;
    }

    if (_animationTicker == null) {
      _animationTicker = createTicker(_onAnimationTick);
      _animationTicker!.start();
    } else if (!_animationTicker!.isActive) {
      _animationTicker!.start();
    }
  }

  void _onAnimationTick(Duration elapsed) {
    final now = DateTime.now();

    if (_animationEndTime != null && now.isBefore(_animationEndTime!)) {
      if (mounted) {
        setState(() {});
      }
    } else {
      _animationTicker?.stop();
      _animationEndTime = null;
    }
  }

  Future<void> preRender(TileDataModel tile) => Future.sync(() {
    tile.preRenderStarted = true;
  });

  void resetState() {
    mapTiles.dispose();
    mapTiles = MapTiles(tileLoader: tileLoader);
    mapTiles.addListener(_updateTiles);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // One pool of worker isolates for every map layer on screen, rather than
    // one per layer (merged from 9.0.0-beta.10).
    executor = acquireSharedExecutor(
      concurrency: widget.mapProperties.concurrency,
    );
    tileLoader = widget.tileLoaderFactory(
      widget.mapProperties,
      executor,
      ThemeRepo(),
    );
    mapTiles = MapTiles(tileLoader: tileLoader);
    _mapAdapter ??= FlutterMapAdapter(
      mapTiles: mapTiles,
      mapUpdated: _mapUpdated,
      tileOffset: widget.mapProperties.tileOffset,
    );
    mapTiles.addListener(_updateTiles);
  }

  void _mapUpdated() {
    if (mounted) {
      setState(() {});
    }
  }
}
