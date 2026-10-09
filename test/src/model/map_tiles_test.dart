import 'package:flutter/widgets.dart';
import 'package:test/test.dart';

import 'package:vector_map_tiles/src/layout/tile_position.dart';
import 'package:vector_map_tiles/src/loader/no_op_tile_loader.dart';
import 'package:vector_map_tiles/src/model/map_tiles.dart';
import 'package:vector_map_tiles/src/tile_identity.dart';
import '../mocks/mock_tile_loader.dart';

void main() {
  group('MapTiles', () {
    late MapTiles mapTiles;

    setUp(() {
      mapTiles = MapTiles(tileLoader: NoOpTileLoader());
    });
    tearDown(() {
      mapTiles.dispose();
    });

    group('initialization', () {
      test('starts with empty tile models', () {
        expect(mapTiles.tileModels, isEmpty);
      });
    });

    group('updateTiles', () {
      test('creates tile models for new tile positions', () {
        final tilePosition = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );

        mapTiles.updateTiles([tilePosition]);

        expect(mapTiles.tileModels, hasLength(1));
        expect(mapTiles.tileModels.first.tile, equals(TileIdentity(1, 0, 0)));
        expect(mapTiles.tileModels.first.tilePosition, equals(tilePosition));
      });

      test('updates existing tile model positions', () {
        final tile = TileIdentity(1, 0, 0);
        final originalPosition = TilePosition(
          tile: tile,
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );
        final updatedPosition = TilePosition(
          tile: tile,
          position: const Rect.fromLTWH(10, 10, 256, 256),
        );

        mapTiles.updateTiles([originalPosition]);
        mapTiles.updateTiles([updatedPosition]);

        expect(mapTiles.tileModels, hasLength(1));
        expect(mapTiles.tileModels.first.tilePosition, equals(updatedPosition));
      });

      test('removes obsolete tiles not in needed tiles', () {
        final tile1 = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );
        final tile2 = TilePosition(
          tile: TileIdentity(1, 1, 0),
          position: const Rect.fromLTWH(256, 0, 256, 256),
        );

        mapTiles.updateTiles([tile1, tile2]);
        expect(mapTiles.tileModels, hasLength(2));

        mapTiles.updateTiles([tile1]);
        expect(mapTiles.tileModels, hasLength(1));
        expect(mapTiles.tileModels.first.tile, equals(TileIdentity(1, 0, 0)));
      });

      test('handles multiple tile updates efficiently', () {
        final tiles = [
          TilePosition(
            tile: TileIdentity(1, 0, 0),
            position: const Rect.fromLTWH(0, 0, 256, 256),
          ),
          TilePosition(
            tile: TileIdentity(1, 1, 0),
            position: const Rect.fromLTWH(256, 0, 256, 256),
          ),
          TilePosition(
            tile: TileIdentity(1, 0, 1),
            position: const Rect.fromLTWH(0, 256, 256, 256),
          ),
        ];

        mapTiles.updateTiles(tiles);

        expect(mapTiles.tileModels, hasLength(3));
        final tileIds = mapTiles.tileModels.map((m) => m.tile).toSet();
        expect(
          tileIds,
          containsAll([
            TileIdentity(1, 0, 0),
            TileIdentity(1, 1, 0),
            TileIdentity(1, 0, 1),
          ]),
        );
      });

      test('ignores updates when disposed', () {
        final disposedMapTiles = MapTiles(tileLoader: NoOpTileLoader());
        disposedMapTiles.dispose();
        final tilePosition = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );

        disposedMapTiles.updateTiles([tilePosition]);

        expect(disposedMapTiles.tileModels, isEmpty);
      });
    });

    group('notification behavior', () {
      test('notifies listeners when tile positions change', () {
        var notificationCount = 0;
        mapTiles.addListener(() => notificationCount++);

        final tilePosition = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );

        mapTiles.updateTiles([tilePosition]);

        expect(notificationCount, equals(1));
      });

      test(
        'does not notify listeners when tile positions remain unchanged',
        () {
          final tilePosition = TilePosition(
            tile: TileIdentity(1, 0, 0),
            position: const Rect.fromLTWH(0, 0, 256, 256),
          );

          mapTiles.updateTiles([tilePosition]);

          var notificationCount = 0;
          mapTiles.addListener(() => notificationCount++);

          mapTiles.updateTiles([tilePosition]);

          expect(notificationCount, equals(0));
        },
      );

      test('notifies listeners when tiles are removed', () {
        final tile1 = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );
        final tile2 = TilePosition(
          tile: TileIdentity(1, 1, 0),
          position: const Rect.fromLTWH(256, 0, 256, 256),
        );

        mapTiles.updateTiles([tile1, tile2]);

        var notificationCount = 0;
        mapTiles.addListener(() => notificationCount++);

        mapTiles.updateTiles([tile1]);

        expect(notificationCount, equals(1));
      });
    });

    group('disposal', () {
      test('clears all tiles and jobs on disposal', () {
        final testMapTiles = MapTiles(tileLoader: NoOpTileLoader());
        final tilePosition = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );

        testMapTiles.updateTiles([tilePosition]);
        expect(testMapTiles.tileModels, hasLength(1));

        testMapTiles.dispose();

        expect(testMapTiles.tileModels, isEmpty);
        expect(testMapTiles.isDisposed, isTrue);
      });

      test('prevents multiple disposal calls', () {
        final testMapTiles = MapTiles(tileLoader: NoOpTileLoader());
        testMapTiles.dispose();
        expect(testMapTiles.isDisposed, isTrue);

        expect(() => testMapTiles.dispose(), returnsNormally);
        expect(testMapTiles.isDisposed, isTrue);
      });
    });

    group('edge cases', () {
      test('handles empty tile updates', () {
        final tilePosition = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );

        mapTiles.updateTiles([tilePosition]);
        expect(mapTiles.tileModels, hasLength(1));

        mapTiles.updateTiles([]);
        expect(mapTiles.tileModels, isEmpty);
      });

      test('handles duplicate tile identities in update', () {
        final tile = TileIdentity(1, 0, 0);
        final position1 = TilePosition(
          tile: tile,
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );
        final position2 = TilePosition(
          tile: tile,
          position: const Rect.fromLTWH(10, 10, 256, 256),
        );

        mapTiles.updateTiles([position1, position2]);

        expect(mapTiles.tileModels, hasLength(1));
        expect(mapTiles.tileModels.first.tilePosition, equals(position2));
      });
    });

    group('tile retention', () {
      late MockTileLoader mockLoader;
      late MapTiles testMapTiles;

      setUp(() {
        mockLoader = MockTileLoader();
        testMapTiles = MapTiles(tileLoader: mockLoader);
      });

      tearDown(() {
        testMapTiles.dispose();
      });

      test(
        'retains display-ready tiles when overlapping tiles are loading',
        () {
          final readyTile = TilePosition(
            tile: TileIdentity(1, 0, 0),
            position: const Rect.fromLTWH(0, 0, 256, 256),
          );
          final loadingTile = TilePosition(
            tile: TileIdentity(2, 0, 0),
            position: const Rect.fromLTWH(0, 0, 128, 128),
          );

          mockLoader.markTileAsReady('z=1,x=0,y=0');
          testMapTiles.updateTiles([readyTile]);
          mockLoader.completeTile('z=1,x=0,y=0');

          testMapTiles.updateTiles([loadingTile]);

          expect(testMapTiles.tileModels, hasLength(2));
          final tileIds = testMapTiles.tileModels.map((m) => m.tile).toSet();
          expect(tileIds, contains(TileIdentity(1, 0, 0)));
          expect(tileIds, contains(TileIdentity(2, 0, 0)));
        },
      );

      test('removes obsolete tiles when no overlapping tiles are loading', () {
        final tile1 = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );
        final tile2 = TilePosition(
          tile: TileIdentity(1, 1, 0),
          position: const Rect.fromLTWH(256, 0, 256, 256),
        );

        mockLoader.markTileAsReady('z=1,x=0,y=0');
        mockLoader.markTileAsReady('z=1,x=1,y=0');
        testMapTiles.updateTiles([tile1, tile2]);
        mockLoader.completeTile('z=1,x=0,y=0');
        mockLoader.completeTile('z=1,x=1,y=0');

        testMapTiles.updateTiles([tile1]);

        expect(testMapTiles.tileModels, hasLength(1));
        expect(
          testMapTiles.tileModels.first.tile,
          equals(TileIdentity(1, 0, 0)),
        );
      });

      test('retains parent tile when child tiles are loading', () {
        final parentTile = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );
        final childTile1 = TilePosition(
          tile: TileIdentity(2, 0, 0),
          position: const Rect.fromLTWH(0, 0, 128, 128),
        );
        final childTile2 = TilePosition(
          tile: TileIdentity(2, 1, 0),
          position: const Rect.fromLTWH(128, 0, 128, 128),
        );

        mockLoader.markTileAsReady('z=1,x=0,y=0');
        testMapTiles.updateTiles([parentTile]);
        mockLoader.completeTile('z=1,x=0,y=0');

        testMapTiles.updateTiles([childTile1, childTile2]);

        expect(testMapTiles.tileModels, hasLength(3));
        final tileIds = testMapTiles.tileModels.map((m) => m.tile).toSet();
        expect(tileIds, contains(TileIdentity(1, 0, 0)));
        expect(tileIds, contains(TileIdentity(2, 0, 0)));
        expect(tileIds, contains(TileIdentity(2, 1, 0)));
      });

      test('retains child tile when parent tile is loading', () {
        final childTile = TilePosition(
          tile: TileIdentity(2, 0, 0),
          position: const Rect.fromLTWH(0, 0, 128, 128),
        );
        final parentTile = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );

        mockLoader.markTileAsReady('z=2,x=0,y=0');
        testMapTiles.updateTiles([childTile]);
        mockLoader.completeTile('z=2,x=0,y=0');

        testMapTiles.updateTiles([parentTile]);

        expect(testMapTiles.tileModels, hasLength(2));
        final tileIds = testMapTiles.tileModels.map((m) => m.tile).toSet();
        expect(tileIds, contains(TileIdentity(1, 0, 0)));
        expect(tileIds, contains(TileIdentity(2, 0, 0)));
      });

      test(
        'removes retained tiles when overlapping tiles finish loading',
        () async {
          final parentTile = TilePosition(
            tile: TileIdentity(1, 0, 0),
            position: const Rect.fromLTWH(0, 0, 256, 256),
          );
          final childTile = TilePosition(
            tile: TileIdentity(2, 0, 0),
            position: const Rect.fromLTWH(0, 0, 128, 128),
          );

          mockLoader.markTileAsReady('z=1,x=0,y=0');
          testMapTiles.updateTiles([parentTile]);
          mockLoader.completeTile('z=1,x=0,y=0');

          testMapTiles.updateTiles([childTile]);
          expect(testMapTiles.tileModels, hasLength(2));

          mockLoader.completeTile('z=2,x=0,y=0');
          await Future.delayed(Duration.zero);

          expect(testMapTiles.tileModels, hasLength(1));
          expect(
            testMapTiles.tileModels.first.tile,
            equals(TileIdentity(2, 0, 0)),
          );
        },
      );

      test(
        'keeps retained tiles until the overlapping tiles are drawn',
        () async {
          final parentTile = TilePosition(
            tile: TileIdentity(1, 0, 0),
            position: const Rect.fromLTWH(0, 0, 256, 256),
          );
          final childTile = TilePosition(
            tile: TileIdentity(2, 0, 0),
            position: const Rect.fromLTWH(0, 0, 128, 128),
          );

          mockLoader.markTileAsReady('z=1,x=0,y=0');
          testMapTiles.updateTiles([parentTile]);
          mockLoader.completeTile('z=1,x=0,y=0');

          await Future.delayed(Duration.zero);

          mockLoader.drawsReadyTiles = false;
          testMapTiles.updateTiles([childTile]);
          mockLoader.completeTile('z=2,x=0,y=0');
          await Future.delayed(Duration.zero);

          // Ready but not yet built by the renderer: the parent still covers it.
          expect(testMapTiles.tileModels, hasLength(2));

          testMapTiles.tileModels
                  .firstWhere((it) => it.tile == TileIdentity(2, 0, 0))
                  .isDrawn =
              true;
          testMapTiles.updateTiles([childTile]);

          expect(testMapTiles.tileModels.single.tile, TileIdentity(2, 0, 0));
        },
      );

      test('does not retain tiles that are not display ready', () {
        final tile1 = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );
        final tile2 = TilePosition(
          tile: TileIdentity(2, 0, 0),
          position: const Rect.fromLTWH(0, 0, 128, 128),
        );

        testMapTiles.updateTiles([tile1]);
        testMapTiles.updateTiles([tile2]);

        expect(testMapTiles.tileModels, hasLength(1));
        expect(
          testMapTiles.tileModels.first.tile,
          equals(TileIdentity(2, 0, 0)),
        );
      });

      test('retains multiple overlapping display-ready tiles', () {
        final parentTile = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );
        final grandparentTile = TilePosition(
          tile: TileIdentity(0, 0, 0),
          position: const Rect.fromLTWH(0, 0, 512, 512),
        );
        final childTile = TilePosition(
          tile: TileIdentity(2, 0, 0),
          position: const Rect.fromLTWH(0, 0, 128, 128),
        );

        mockLoader.markTileAsReady('z=0,x=0,y=0');
        mockLoader.markTileAsReady('z=1,x=0,y=0');
        testMapTiles.updateTiles([grandparentTile, parentTile]);
        mockLoader.completeTile('z=0,x=0,y=0');
        mockLoader.completeTile('z=1,x=0,y=0');

        testMapTiles.updateTiles([childTile]);

        expect(testMapTiles.tileModels, hasLength(3));
        final tileIds = testMapTiles.tileModels.map((m) => m.tile).toSet();
        expect(tileIds, contains(TileIdentity(0, 0, 0)));
        expect(tileIds, contains(TileIdentity(1, 0, 0)));
        expect(tileIds, contains(TileIdentity(2, 0, 0)));
      });

      test('does not retain tiles that do not overlap with loading tiles', () {
        final tile1 = TilePosition(
          tile: TileIdentity(1, 0, 0),
          position: const Rect.fromLTWH(0, 0, 256, 256),
        );
        final tile2 = TilePosition(
          tile: TileIdentity(1, 1, 0),
          position: const Rect.fromLTWH(256, 0, 256, 256),
        );
        final tile3 = TilePosition(
          tile: TileIdentity(1, 0, 1),
          position: const Rect.fromLTWH(0, 256, 256, 256),
        );

        mockLoader.markTileAsReady('z=1,x=0,y=0');
        mockLoader.markTileAsReady('z=1,x=1,y=0');
        testMapTiles.updateTiles([tile1, tile2]);
        mockLoader.completeTile('z=1,x=0,y=0');
        mockLoader.completeTile('z=1,x=1,y=0');

        testMapTiles.updateTiles([tile3]);

        expect(testMapTiles.tileModels, hasLength(1));
        expect(
          testMapTiles.tileModels.first.tile,
          equals(TileIdentity(1, 0, 1)),
        );
      });
    });
  });
}
