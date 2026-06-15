// lib/screens/prototype_editor_screen.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'dart:convert';
import '../models/project.dart';
import '../services/api_service.dart';

class BoundingBoxRect {
  Offset start;
  Offset end;
  String label;
  BoundingBoxRect({
    required this.start,
    required this.end,
    required this.label,
  });
}

Color getColorForLabel(String label) {
  final List<Color> colors = [
    Colors.red,
    Colors.green,
    Colors.blue,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.pink,
    Colors.amber,
    Colors.cyan,
    Colors.indigo,
    Colors.lime,
    Colors.brown,
  ];
  int hash = 0;
  for (var code in label.codeUnits) {
    hash += code;
  }
  return colors[hash % colors.length];
}

class PrototypeEditorScreen extends StatefulWidget {
  final Project project;
  const PrototypeEditorScreen({super.key, required this.project});

  @override
  State<PrototypeEditorScreen> createState() => _PrototypeEditorScreenState();
}

class _PrototypeEditorScreenState extends State<PrototypeEditorScreen> {
  File? _localImageFile;
  String? _networkImageUrl;
  final List<BoundingBoxRect> _boundingBoxes = [];

  // FIX: Store the in-progress box start/end separately so we never
  // mutate a committed box and trigger a stale-coordinate rebuild.
  Offset? _dragStart;
  Offset? _dragCurrent;

  final ImagePicker _picker = ImagePicker();
  final _imageKey = GlobalKey();

  final TransformationController _transformationController =
      TransformationController();
  bool _isDrawingMode = false;
  bool _isLoading = false;
  double? _imageAspect;

  @override
  void initState() {
    super.initState();
    _initializePrototypeData();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  Future<void> _initializePrototypeData() async {
    if (widget.project.prototypePath != null &&
        widget.project.prototypePath!.isNotEmpty) {
      setState(() => _isLoading = true);
      _networkImageUrl =
          '${ApiService.baseUrl}/${widget.project.prototypePath}';

      Size dims = await _getImageDimensions();
      _imageAspect = dims.width / dims.height;

      await _fetchExistingBoxes();
    }
  }

  Future<void> _fetchExistingBoxes() async {
    try {
      Dio dio = Dio();
      String url = '${ApiService.baseUrl}/projects/${widget.project.id}/boxes';
      Response response = await dio.get(url);

      if (response.statusCode == 200 && response.data != null) {
        final List<dynamic> fetchedData = response.data;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await _convertNormalizedBoxesToScreen(fetchedData);
        });
      }
    } catch (e) {
      debugPrint("Error fetching existing bounding boxes: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<Size> _getImageDimensions() async {
    final Completer<Size> completer = Completer<Size>();
    ImageProvider provider;

    if (_localImageFile != null) {
      provider = FileImage(_localImageFile!);
    } else if (_networkImageUrl != null) {
      provider = NetworkImage(_networkImageUrl!);
    } else {
      return const Size(1000, 1000);
    }

    final ImageStream stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) {
        if (!completer.isCompleted) {
          completer.complete(
            Size(info.image.width.toDouble(), info.image.height.toDouble()),
          );
        }
        stream.removeListener(listener);
      },
      onError: (dynamic exception, StackTrace? stackTrace) {
        if (!completer.isCompleted) completer.complete(const Size(1000, 1000));
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  Future<void> _convertNormalizedBoxesToScreen(
    List<dynamic> serverBoxes,
  ) async {
    if (_imageKey.currentContext == null) return;

    Size originalSize = await _getImageDimensions();
    final RenderBox widgetBox =
        _imageKey.currentContext!.findRenderObject() as RenderBox;
    final Size widgetSize = widgetBox.size;

    final double scaleX = originalSize.width / widgetSize.width;
    final double scaleY = originalSize.height / widgetSize.height;

    setState(() {
      _boundingBoxes.clear();
      for (var box in serverBoxes) {
        _boundingBoxes.add(
          BoundingBoxRect(
            start: Offset(box['x1'] / scaleX, box['y1'] / scaleY),
            end: Offset(box['x2'] / scaleX, box['y2'] / scaleY),
            label: box['label'] ?? 'target_component',
          ),
        );
      }
    });
  }

  Future<void> _pickImage() async {
    final XFile? pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
    );
    if (pickedFile != null) {
      setState(() => _isLoading = true);
      _localImageFile = File(pickedFile.path);
      _networkImageUrl = null;
      _boundingBoxes.clear();
      _dragStart = null;
      _dragCurrent = null;
      _transformationController.value = Matrix4.identity();

      Size dims = await _getImageDimensions();
      setState(() {
        _imageAspect = dims.width / dims.height;
        _isLoading = false;
      });
    }
  }

  Future<void> _submitPrototype() async {
    if (_localImageFile == null && _networkImageUrl == null) return;
    if (_imageKey.currentContext == null) return;

    Size originalSize = await _getImageDimensions();
    final RenderBox widgetBox =
        _imageKey.currentContext!.findRenderObject() as RenderBox;
    final Size widgetSize = widgetBox.size;

    final double scaleX = originalSize.width / widgetSize.width;
    final double scaleY = originalSize.height / widgetSize.height;

    List<Map<String, dynamic>> normalizedBoxes = _boundingBoxes.map((box) {
      return {
        "label": box.label,
        "x1": box.start.dx * scaleX,
        "y1": box.start.dy * scaleY,
        "x2": box.end.dx * scaleX,
        "y2": box.end.dy * scaleY,
      };
    }).toList();

    try {
      Dio dio = Dio();

      if (_localImageFile != null) {
        String uploadUrl =
            '${ApiService.baseUrl}/projects/${widget.project.id}/prototype';
        FormData formData = FormData.fromMap({
          "file": await MultipartFile.fromFile(
            _localImageFile!.path,
            filename: "prototype.jpg",
          ),
          "boxes": jsonEncode(normalizedBoxes),
        });
        await dio.post(uploadUrl, data: formData);
      } else {
        String updateUrl =
            '${ApiService.baseUrl}/projects/${widget.project.id}/boxes';
        await dio.put(updateUrl, data: {"boxes": normalizedBoxes});
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Layout state synchronized successfully'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Synchronization failure: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FIX: Convert a raw GestureDetector localPosition into the coordinate
  // space of the image widget (keyed by _imageKey).
  //
  // The GestureDetector sits on the Stack that exactly matches the image
  // widget's size/position (see build()), so localPosition IS already in
  // image-space.  We clamp to the image bounds for safety.
  // ─────────────────────────────────────────────────────────────────────────
  Offset _clampToImage(Offset raw) {
    if (_imageKey.currentContext == null) return raw;
    final RenderBox box =
        _imageKey.currentContext!.findRenderObject() as RenderBox;
    return Offset(
      raw.dx.clamp(0.0, box.size.width),
      raw.dy.clamp(0.0, box.size.height),
    );
  }

  void _onDrawStart(DragStartDetails details) {
    setState(() {
      _dragStart = _clampToImage(details.localPosition);
      _dragCurrent = _dragStart;
    });
  }

  void _onDrawUpdate(DragUpdateDetails details) {
    setState(() {
      _dragCurrent = _clampToImage(details.localPosition);
    });
  }

  Future<void> _onDrawEnd(DragEndDetails details) async {
    if (_dragStart == null || _dragCurrent == null) return;

    // Capture the coordinates before any async gap / setState clears them.
    final Offset capturedStart = _dragStart!;
    final Offset capturedEnd = _dragCurrent!;

    // Clear the live preview immediately so nothing shifts during the dialog.
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
    });

    // Ignore accidental taps (box too small).
    final rect = Rect.fromPoints(capturedStart, capturedEnd);
    if (rect.width < 5 || rect.height < 5) return;

    final TextEditingController labelController = TextEditingController();
    final String? assignedLabel = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Identify Component'),
        content: TextField(
          controller: labelController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g., ARDUINO, capacitor',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Discard'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, labelController.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (assignedLabel != null && assignedLabel.trim().isNotEmpty) {
      // FIX: Use the captured (pre-dialog) coordinates — never re-read
      // any layout-dependent value after an async gap.
      setState(() {
        _boundingBoxes.add(
          BoundingBoxRect(
            start: capturedStart,
            end: capturedEnd,
            label: assignedLabel.trim().toUpperCase(),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget? imageWidget;
    if (_localImageFile != null) {
      imageWidget = Image.file(
        _localImageFile!,
        key: _imageKey,
        fit: BoxFit.contain,
      );
    } else if (_networkImageUrl != null) {
      imageWidget = Image.network(
        _networkImageUrl!,
        key: _imageKey,
        fit: BoxFit.contain,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Prototype Workspace: ${widget.project.name}'),
        actions: [
          if (_localImageFile != null || _networkImageUrl != null)
            IconButton(
              icon: const Icon(Icons.check_circle_outline),
              onPressed: _submitPrototype,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : imageWidget == null
          ? Center(
              child: ElevatedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.image),
                label: const Text('Load Prototype Layout Context'),
              ),
            )
          : Column(
              children: [
                // ── Mode toggle bar ──────────────────────────────────
                Container(
                  color: Colors.grey[200],
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 16,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _isDrawingMode ? Icons.brush : Icons.zoom_out_map,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isDrawingMode
                                ? "Active Mode: Labeling Component"
                                : "Active Mode: Navigating Viewport",
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      Switch(
                        value: _isDrawingMode,
                        onChanged: (val) =>
                            setState(() => _isDrawingMode = val),
                      ),
                    ],
                  ),
                ),

                // ── Main canvas ──────────────────────────────────────
                Expanded(
                  child: ClipRect(
                    child: InteractiveViewer(
                      transformationController: _transformationController,
                      // Disable pan/scale while drawing so the viewer
                      // doesn't compete with the GestureDetector.
                      panEnabled: !_isDrawingMode,
                      scaleEnabled: !_isDrawingMode,
                      minScale: 1.0,
                      maxScale: 6.0,
                      child: _imageAspect == null
                          ? const SizedBox()
                          : Center(
                              child: AspectRatio(
                                aspectRatio: _imageAspect!,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    // Layer 0 – the image itself
                                    imageWidget!,

                                    // Layer 1 – committed boxes + live
                                    //           preview, painted over the
                                    //           image in the same space.
                                    CustomPaint(
                                      painter: CanvasBBoxPainter(
                                        boxes: _boundingBoxes,
                                        dragStart: _dragStart,
                                        dragCurrent: _dragCurrent,
                                      ),
                                    ),

                                    // Layer 2 – transparent hit-test surface
                                    //           for drawing gestures ONLY.
                                    //
                                    // FIX: The GestureDetector is placed
                                    // here, *inside* the Stack that is
                                    // already sized to the image. Its
                                    // localPosition therefore maps 1-to-1
                                    // with the image pixels rendered on
                                    // screen — no extra offset from Center
                                    // or AspectRatio to compensate for.
                                    if (_isDrawingMode)
                                      Positioned.fill(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onPanStart: _onDrawStart,
                                          onPanUpdate: _onDrawUpdate,
                                          onPanEnd: _onDrawEnd,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),
                ),

                // ── Legend ───────────────────────────────────────────
                if (_boundingBoxes.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    width: double.infinity,
                    color: Colors.grey[100],
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: _boundingBoxes.map((b) => b.label).toSet().map((
                        label,
                      ) {
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: getColorForLabel(label),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              label,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),

                // ── Bottom action bar ────────────────────────────────
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red[50],
                        ),
                        onPressed: () => setState(() => _boundingBoxes.clear()),
                        icon: const Icon(Icons.delete_sweep, color: Colors.red),
                        label: const Text(
                          'Clear Elements',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _pickImage,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Swap Image Source'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Painter
// FIX: Accepts raw start/current drag offsets instead of a mutable
// BoundingBoxRect.  This avoids reading stale / mutated state after the
// dialog's async gap.
// ──────────────────────────────────────────────────────────────────────────────
class CanvasBBoxPainter extends CustomPainter {
  final List<BoundingBoxRect> boxes;
  final Offset? dragStart;
  final Offset? dragCurrent;

  CanvasBBoxPainter({required this.boxes, this.dragStart, this.dragCurrent});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0; // slightly thicker for visibility

    // Draw committed boxes.
    for (var box in boxes) {
      paint.color = getColorForLabel(box.label);
      canvas.drawRect(Rect.fromPoints(box.start, box.end), paint);

      // Label text inside the box (top-left corner).
      final textPainter = TextPainter(
        text: TextSpan(
          text: ' ${box.label} ',
          style: TextStyle(
            color: getColorForLabel(box.label),
            fontSize: 11,
            fontWeight: FontWeight.bold,
            background: Paint()..color = Colors.black.withOpacity(0.45),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, box.start);
    }

    // Draw the live "rubber-band" preview while the user is still dragging.
    if (dragStart != null && dragCurrent != null) {
      final livePaint = Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(Rect.fromPoints(dragStart!, dragCurrent!), livePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CanvasBBoxPainter oldDelegate) =>
      oldDelegate.dragStart != dragStart ||
      oldDelegate.dragCurrent != dragCurrent ||
      oldDelegate.boxes.length != boxes.length;
}
