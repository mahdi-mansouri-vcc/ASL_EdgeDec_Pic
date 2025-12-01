// lib/src/edge_overlay_saver_web.dart
import 'dart:convert';
import 'dart:typed_data';
import 'dart:html' as html;

Future<String?> saveOverlayBytes(Uint8List bytes) async {
  final base64 = base64Encode(bytes);
  final dataUrl = 'data:image/png;base64,$base64';

  final anchor = html.AnchorElement(href: dataUrl)
    ..download = 'edges_overlay.png'
    ..click();

  // No real path on web, just return a human-friendly message
  return 'Downloaded as edges_overlay.png';
}