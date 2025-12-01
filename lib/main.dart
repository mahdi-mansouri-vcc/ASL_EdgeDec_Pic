import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

// NEW: conditional import for saving the overlay (IO vs Web)
import 'src/edge_overlay_saver_stub.dart'
    if (dart.library.html) 'src/edge_overlay_saver_web.dart'
    if (dart.library.io) 'src/edge_overlay_saver_io.dart';


Future<Size> _pngSize(Uint8List bytes) async {
  final c = Completer<Size>();
  ui.decodeImageFromList(bytes, (img) {
    c.complete(Size(img.width.toDouble(), img.height.toDouble()));
  });
  return c.future;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(EdgeCamApp(cameras: cameras));
}
 
class EdgeCamApp extends StatelessWidget {
  const EdgeCamApp({super.key, required this.cameras});
  final List<CameraDescription> cameras;
 
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EdgeCam',
      theme: ThemeData(
        colorSchemeSeed: Colors.green,
        useMaterial3: true,
      ),
      home: EdgeCamHome(cameras: cameras),
    );
  }
}
 
class EdgeCamHome extends StatefulWidget {
  const EdgeCamHome({super.key, required this.cameras});
  final List<CameraDescription> cameras;
 
  @override
  State<EdgeCamHome> createState() => _EdgeCamHomeState();
}
 
class _EdgeCamHomeState extends State<EdgeCamHome> {
  CameraController? _controller;
  Future<void>? _initFuture;
  XFile? _lastShot;
  Uint8List? _lastShotBytes;   // <--- NEW
  Uint8List? _overlayPng;
  bool _busy = false;
  double _threshold = 90;
  final ImagePicker _picker = ImagePicker();
  final TransformationController _zoomCtrl = TransformationController();
  void _resetZoom() => _zoomCtrl.value = Matrix4.identity();
  
  Size? _overlaySize; // set after each edge-detect run

  Future<void> _pickFromGalleryAndProcess() async {
    setState(() => _busy = true);
    try {
      final XFile? picked =
          await _picker.pickImage(source: ImageSource.gallery);
      if (picked == null) {
        // User canceled the picker
        return;
      }

      _lastShot = picked;

      final bytes = await picked.readAsBytes();
      _lastShotBytes = bytes;

      final result = await compute<_EdgeJob, _EdgeResult>(
        _edgeDetectIsolate,
        _EdgeJob(imageBytes: bytes, threshold: _threshold, maxDim: 1080),
      );

      if (!mounted) return;
      setState(() => _overlayPng = result.overlayPng);

      _overlaySize = await _pngSize(_overlayPng!);
      if (mounted) setState(() {});
      _resetZoom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _takeAndProcess() async {
    if (_controller == null) return;
    setState(() => _busy = true);
    try {
      final shot = await _controller!.takePicture();
      _lastShot = shot;

      final bytes = await shot.readAsBytes();
      _lastShotBytes = bytes;

      final result = await compute<_EdgeJob, _EdgeResult>(
        _edgeDetectIsolate,
        _EdgeJob(imageBytes: bytes, threshold: _threshold, maxDim: 1080),
      );

      if (!mounted) return;
      setState(() => _overlayPng = result.overlayPng);

      _overlaySize = await _pngSize(_overlayPng!);
      if (mounted) setState(() {});
      _resetZoom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
 
  Future<void> _restartCamera() async {
    // Indicate we’re busy so the Capture button is disabled
    setState(() {
      _busy = true;
    });

    // Dispose old controller (if any)
    await _controller?.dispose();

    // Pick the same camera as in initState
    final cam = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );

    // Create and initialize a new controller
    _controller = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    _initFuture = _controller!.initialize();
    await _initFuture;

    if (!mounted) return;
    setState(() {
      _busy = false;
    });
  }

  Future<void> _reprocessLast() async {
    if (_lastShot == null) return;
    final bytes = _lastShotBytes ?? await _lastShot!.readAsBytes();

    final result = await compute<_EdgeJob, _EdgeResult>(
      _edgeDetectIsolate,
      _EdgeJob(imageBytes: bytes, threshold: _threshold, maxDim: 1080),
    );

    if (!mounted) return;
    setState(() => _overlayPng = result.overlayPng);

    _overlaySize = await _pngSize(_overlayPng!);
    if (mounted) setState(() {});
    _resetZoom();
  }
 
  Widget _buildResult() {
    if (_overlayPng == null || _lastShotBytes == null) {
      return const SizedBox.shrink();
    }
    if (_overlaySize == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final w = _overlaySize!.width;
    final h = _overlaySize!.height;

    return ClipRect(
      child: GestureDetector(
        onDoubleTap: _resetZoom,
        child: InteractiveViewer(
          transformationController: _zoomCtrl,
          child: Center(
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    _lastShotBytes!,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.high,
                  ),
                  Image.memory(
                    _overlayPng!,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _zoomCtrl.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final cam = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );
    _controller = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _initFuture = _controller!.initialize();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ASL EdgeDec by Mahdi'),
        actions: [
          IconButton(
            tooltip: 'Reset zoom',
            onPressed: _resetZoom,
            icon: const Icon(Icons.center_focus_strong),
          ),
          IconButton(
            tooltip: 'Upload photo',
            onPressed: _busy ? null : _pickFromGalleryAndProcess,
            icon: const Icon(Icons.photo_library_outlined),
          ),
          IconButton(
            tooltip: 'Save overlay',
            onPressed: (_overlayPng == null)
                ? null
                : () async {
                    try {
                      final savedInfo = await saveOverlayBytes(_overlayPng!);

                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            savedInfo == null
                                ? 'Save canceled.'
                                : 'Saved: $savedInfo',
                          ),
                        ),
                      );
                    } catch (e, st) {
                      debugPrint('Save failed: $e\n$st');
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Save failed (see logs).'),
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.save_alt),
          ),
        ],
      ),

      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 44.0), // Adjust the padding as needed
        child: FloatingActionButton.extended(
          onPressed: _busy ? null : _takeAndProcess,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.camera),
          label: const Text('Capture'),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    
      /// BODY: Camera preview or image+overlay
      body: FutureBuilder(
        future: _initFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              Expanded(
                child: Center(
                  child: _lastShot == null
                      ? CameraPreview(_controller!)
                      :_buildResult(), 
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const Text('Threshold',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      Expanded(
                        child: Slider(
                          min: 20,
                          max: 200,
                          divisions: 180,
                          value: _threshold,
                          label: _threshold.round().toString(),
                          onChanged: (v) => setState(() => _threshold = v),
                          onChangeEnd: (_) {
                            if (_lastShot != null) _reprocessLast();
                          },
                        ),
                      ),
                      if (_lastShot != null)
                        IconButton(
                          tooltip: 'Retake',
                          icon: const Icon(Icons.refresh),
                          onPressed: () async {
                            // Clear the current result
                            setState(() {
                              _lastShot = null;
                              _overlayPng = null;
                              _overlaySize = null;  // also reset size cache
                            });

                            // Restart the camera preview
                            await _restartCamera();
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
 
// ---------- Image processing (isolate) ----------
class _EdgeJob {
  final Uint8List imageBytes;
  final double threshold;
  final int maxDim;
  const _EdgeJob({
    required this.imageBytes,
    required this.threshold,
    required this.maxDim,
  });
}
 
class _EdgeResult {
  final Uint8List overlayPng;
  const _EdgeResult({required this.overlayPng});
}
 
_EdgeResult _edgeDetectIsolate(_EdgeJob job) {
  img.Image? decoded = img.decodeImage(job.imageBytes);
  if (decoded == null) throw 'Failed to decode image';
  // Downscale for speed
  if (decoded.width > job.maxDim || decoded.height > job.maxDim) {
    final scale = math.min(job.maxDim / decoded.width,
        job.maxDim / decoded.height);
    decoded = img.copyResize(decoded,
        width: (decoded.width * scale).round(),
        height: (decoded.height * scale).round());
  }
  final gray = img.grayscale(decoded);
  final edges = _sobel(gray);
  final w = edges.width, h = edges.height;
  final overlay = img.Image(width: w, height: h, numChannels: 4);
  final threshold = job.threshold;
  final bytes = edges.getBytes(order: img.ChannelOrder.rgba);
  for (int i = 0; i < w * h; i++) {
    final lum = bytes[i * 4];
    if (lum > threshold) {
      overlay.setPixelRgba(i % w, i ~/ w, 0, 255, 0, 255);
    } else {
      overlay.setPixelRgba(i % w, i ~/ w, 0, 255, 0, 0);
    }
  }
  return _EdgeResult(overlayPng: Uint8List.fromList(img.encodePng(overlay)));
}
 
img.Image _sobel(img.Image src) {
  final w = src.width, h = src.height;
  final data = src.getBytes(order: img.ChannelOrder.rgba);
  final lum = Float32List(w * h);
  for (int i = 0, j = 0; i < data.length; i += 4, j++) {
    lum[j] = data[i].toDouble();
  }
  const gx = [
    [-1.0, 0.0, 1.0],
    [-2.0, 0.0, 2.0],
    [-1.0, 0.0, 1.0],
  ];
  const gy = [
    [1.0, 2.0, 1.0],
    [0.0, 0.0, 0.0],
    [-1.0, -2.0, -1.0],
  ];
  final out = img.Image(width: w, height: h);
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      double sx = 0, sy = 0;
      for (int ky = -1; ky <= 1; ky++) {
        for (int kx = -1; kx <= 1; kx++) {
          final v = lum[(y + ky) * w + (x + kx)];
          sx += v * gx[ky + 1][kx + 1];
          sy += v * gy[ky + 1][kx + 1];
        }
      }
      final mag = math.sqrt(sx * sx + sy * sy);
      final m = mag.clamp(0, 255).toInt();
      out.setPixelRgba(x, y, m, m, m, 255);
    }
  }
  return out;
}