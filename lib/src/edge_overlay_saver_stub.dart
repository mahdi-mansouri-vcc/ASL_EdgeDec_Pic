// lib/src/edge_overlay_saver_stub.dart
import 'dart:typed_data';

Future<String?> saveOverlayBytes(Uint8List bytes) async {
  // Fallback for unsupported platforms (mainly for tests)
  throw UnsupportedError(
    'Saving overlay is not supported on this platform.',
  );
}