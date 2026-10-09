import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:executor_lib/executor_lib.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../tile_translation.dart';
import 'theme_repo.dart';
import 'translation_applier.dart';

class VectorTileTransform {
  final Executor executor;
  final Theme theme;
  final ThemeRepo themeRepo;
  final double tileSize;

  VectorTileTransform({
    required this.executor,
    required this.theme,
    required this.tileSize,
    required this.themeRepo,
  }) {
    themeRepo.initialize(theme, executor);
  }

  Future<Tile> apply(
    Uint8List bytes,
    TileTranslation translation,
    bool Function() cancelled,
  ) async {
    final themeId = theme.id;
    if (!themeRepo.isThemeReady(themeId)) {
      await themeRepo.waitForTheme(themeId);
    }
    final deduplicationKey =
        '${theme.id}-${theme.version}-${translation.original.key()}-${translation.translated.key()}-${translation.xOffset}-${translation.yOffset}';
    return await executor.submit(
      Job(
        deduplicationKey,
        _apply,
        _TransformInput(
          themeId: theme.id,
          tileSize: tileSize,
          bytes: TransferableTypedData.fromList([bytes]),
          translation: translation,
        ),
        cancelled: cancelled,
        deduplicationKey: deduplicationKey,
      ),
    );
  }
}

class _TransformInput {
  final String themeId;
  final TransferableTypedData bytes;
  final double tileSize;
  final TileTranslation translation;

  _TransformInput({
    required this.themeId,
    required this.bytes,
    required this.tileSize,
    required this.translation,
  });
}

Tile _apply(_TransformInput input) => parseSourceTile(
  themeId: input.themeId,
  bytes: input.bytes.materialize().asUint8List(),
  translation: input.translation,
  tileSize: input.tileSize,
);

/// A source tile's bytes read, styled for [themeId] and translated, as the
/// load does it. Also run by the pre-render job, which is sent these bytes
/// rather than the parsed tile: copying a parsed tile (thousands of small
/// objects) to a worker isolate is done by the sender, the UI isolate.
Tile parseSourceTile({
  required String themeId,
  required Uint8List bytes,
  required TileTranslation translation,
  required double tileSize,
}) {
  final theme = ThemeRepo.themeById[themeId]!;
  final vectorTile = VectorTileReader().read(bytes);
  final tileData = TileFactory(
    theme,
    const Logger.noop(),
  ).createTileData(vectorTile);
  final translated = TranslationApplier(
    tileSize: tileSize,
  ).apply(tileData, translation);
  return translated.toTile();
}
