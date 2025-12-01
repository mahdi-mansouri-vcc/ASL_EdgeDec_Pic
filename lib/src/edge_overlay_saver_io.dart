// lib/src/edge_overlay_saver_io.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';

Future<String?> saveOverlayBytes(Uint8List bytes) async {
  // Write bytes to a temp file first
  final tempDir = await getTemporaryDirectory();
  final tmpPath = '${tempDir.path}/edges_overlay.png';
  final tmpFile = File(tmpPath);
  await tmpFile.writeAsBytes(bytes, flush: true);

  // Show system Save dialog (user can choose Downloads)
  final savedPath = await FlutterFileDialog.saveFile(
    params: SaveFileDialogParams(
      sourceFilePath: tmpPath,
      fileName: 'edges_overlay.png',
      mimeTypesFilter: const ['image/png'],
    ),
  );

  return savedPath; // null if canceled
}