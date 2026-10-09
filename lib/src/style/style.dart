import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../provider/network_vector_tile_provider.dart';
import '../tile_providers.dart';
import '../vector_tile_provider.dart';
import 'uri_mapper.dart';

class Style {
  final String? name;
  final Theme theme;
  final TileProviders providers;
  final SpriteStyle? sprites;
  final LatLng? center;
  final double? zoom;

  Style({
    this.name,
    required this.theme,
    required this.providers,
    this.sprites,
    this.center,
    this.zoom,
  });
}

class SpriteStyle {
  final Future<Uint8List> Function() atlasProvider;
  final SpriteIndex index;

  SpriteStyle({required this.atlasProvider, required this.index});
}

class StyleReader {
  final String uri;
  final String? apiKey;
  final Logger logger;
  final Map<String, String>? httpHeaders;

  StyleReader({
    required this.uri,
    this.apiKey,
    Logger? logger,
    this.httpHeaders,
  }) : logger = logger ?? const Logger.noop();

  Future<Style> read() async {
    final uriMapper = StyleUriMapper(key: apiKey);
    final url = uriMapper.map(uri);
    final styleText = await _httpGet(url, httpHeaders);
    final style = await compute(jsonDecode, styleText);
    if (style is! Map<String, dynamic>) {
      throw _invalidStyle(url);
    }
    final sources = style['sources'];
    if (sources is! Map) {
      throw _invalidStyle(url);
    }
    // Everything after the style itself is fetched at once: one request after
    // another (a source's TileJSON each, then the sprite index) took seconds
    // on a phone, every launch.
    final (providerByName, sprites) = await (
      _readProviderByName(sources),
      _readSprites(uriMapper, style['sprite']),
    ).wait;
    final name = style['name'] as String?;

    final center = style['center'];
    LatLng? centerPoint;
    if (center is List && center.length == 2) {
      centerPoint = LatLng(
        (center[1] as num).toDouble(),
        (center[0] as num).toDouble(),
      );
    }
    double? zoom = (style['zoom'] as num?)?.toDouble();
    if (zoom != null && zoom < 2) {
      zoom = null;
      centerPoint = null;
    }
    return Style(
      theme: ThemeReader(logger: logger).read(style),
      providers: TileProviders(providerByName),
      sprites: sprites,
      name: name,
      center: centerPoint,
      zoom: zoom,
    );
  }

  Future<SpriteStyle?> _readSprites(
    StyleUriMapper uriMapper,
    Object? spriteUri,
  ) async {
    if (spriteUri is! String || spriteUri.trim().isEmpty) return null;
    for (final spriteUri in uriMapper.mapSprite(uri, spriteUri)) {
      dynamic spritesJson;
      try {
        final spritesJsonText = await _httpGet(spriteUri.json, httpHeaders);
        spritesJson = await compute(jsonDecode, spritesJsonText);
      } catch (e) {
        logger.log(() => 'error reading sprite uri: ${spriteUri.json}');
        continue;
      }
      return SpriteStyle(
        atlasProvider: () => _loadBinary(spriteUri.image, httpHeaders),
        index: SpriteIndexReader(logger: logger).read(spritesJson),
      );
    }
    return null;
  }

  Future<Map<String, VectorTileProvider>> _readProviderByName(
    Map sources,
  ) async {
    final entries = sources.entries.toList();
    final read = await Future.wait(entries.map(_readProvider));
    final providers = <String, VectorTileProvider>{
      for (var i = 0; i < entries.length; i++)
        if (read[i] != null) entries[i].key as String: read[i]!,
    };
    if (providers.isEmpty) {
      throw 'Unexpected response';
    }
    return providers;
  }

  Future<VectorTileProvider?> _readProvider(MapEntry entry) async {
    final sourceType = entry.value['type'];
    var type = TileProviderType.values
        .where((e) => e.name.replaceAll('_', '-') == sourceType)
        .firstOrNull;
    if (type == null) return null;
    dynamic source;
    var entryUrl = entry.value['url'] as String?;
    if (entryUrl != null) {
      final sourceUrl = StyleUriMapper(key: apiKey).mapSource(uri, entryUrl);
      source = await compute(
        jsonDecode,
        await _httpGet(sourceUrl, httpHeaders),
      );
      if (source is! Map) {
        throw _invalidStyle(sourceUrl);
      }
    } else {
      source = entry.value;
    }
    final entryTiles = source['tiles'];
    final maxzoom = source['maxzoom'] as int? ?? 14;
    final minzoom = source['minzoom'] as int? ?? 1;
    if (entryTiles is List && entryTiles.isNotEmpty) {
      final tileUri = entryTiles[0] as String;
      final tileUrl = StyleUriMapper(key: apiKey).mapTiles(tileUri);
      return NetworkVectorTileProvider(
        type: type,
        urlTemplate: tileUrl,
        maximumZoom: maxzoom,
        minimumZoom: minzoom,
        httpHeaders: httpHeaders,
      );
    }
    return null;
  }
}

String _invalidStyle(String url) =>
    'Uri does not appear to be a valid style: $url';

Future<String> _httpGet(String url, Map<String, String>? httpHeaders) async {
  final response = await get(Uri.parse(url), headers: httpHeaders);
  if (response.statusCode == 200) {
    return response.body;
  } else {
    throw 'HTTP ${response.statusCode}: ${response.body}';
  }
}

Future<Uint8List> _loadBinary(
  String url,
  Map<String, String>? httpHeaders,
) async {
  final response = await get(Uri.parse(url), headers: httpHeaders);
  if (response.statusCode == 200) {
    return response.bodyBytes;
  } else {
    throw 'HTTP ${response.statusCode}: ${response.body}';
  }
}
