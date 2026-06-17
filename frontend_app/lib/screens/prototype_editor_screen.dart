// lib/screens/prototype_editor_screen.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'dart:convert';
import '../models/project.dart';
import '../services/api_service.dart';

/// Stores coordinates NORMALIZED to [0,1] relative to the image dimensions.
class BoundingBoxRect {
  double x1, y1, x2, y2; // all in [0, 1]
  String label;

  BoundingBoxRect({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.label,
  });
}

const List<String> kAvailableLabels = [
  'capacitor', 'resistor', 'LED', 'IC', 'transistor', 'switch',
  'headers', 'microcontroller', 'icsp', 'ATmega328 microcontroller',
  'crystal oscillator', 'voltage regulator', 'r105', 'comp1', 'comp2',
  'comp3', 'usb', 'dc',
];

Color getColorForLabel(String label) {
  final List<Color> colors = [
    Colors.red, Colors.green, Colors.blue, Colors.orange, Colors.purple,
    Colors.teal, Colors.pink, Colors.amber, Colors.cyan, Colors.indigo,
    Colors.lime, Colors.brown,
  ];
  int hash = label.codeUnits.fold(0, (a, b) => a + b);
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

  // Live drag - also in normalized [0,1] coords
  Offset? _dragStartNorm;
  Offset? _dragCurrentNorm;

  final ImagePicker _picker = ImagePicker();
  final _imageKey = GlobalKey();
  final TransformationController _transformationController = TransformationController();

  bool _isDrawingMode = false;
  bool _isLoading = false;
  double? _imageAspect;
  String? _selectedLabel;

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
      _networkImageUrl = '${ApiService.baseUrl}/${widget.project.prototypePath}';
      Size dims = await _getImageDimensions();
      _imageAspect = dims.width / dims.height;
      await _fetchExistingBoxes();
    }
  }

  Future<void> _fetchExistingBoxes() async {
    try {
      Dio dio = Dio();
      Response response = await dio.get(
        '${ApiService.baseUrl}/projects/${widget.project.id}/boxes',
      );
      if (response.statusCode == 200 && response.data != null) {
        final Size originalSize = await _getImageDimensions();
        final List<dynamic> fetched = response.data;
        setState(() {
          _boundingBoxes.clear();
          for (var box in fetched) {
            // Server sends pixel coords -> normalize to [0,1]
            _boundingBoxes.add(BoundingBoxRect(
              x1: (box['x1'] as num) / originalSize.width,
              y1: (box['y1'] as num) / originalSize.height,
              x2: (box['x2'] as num) / originalSize.width,
              y2: (box['y2'] as num) / originalSize.height,
              label: box['label'] ?? 'target_component',
            ));
          }
        });
      }
    } catch (e) {
      debugPrint("Error fetching boxes: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<Size> _getImageDimensions() async {
    final Completer<Size> completer = Completer<Size>();
    ImageProvider provider = _localImageFile != null
        ? FileImage(_localImageFile!) as ImageProvider
        : _networkImageUrl != null
            ? NetworkImage(_networkImageUrl!)
            : const NetworkImage('');

    if (_localImageFile == null && _networkImageUrl == null) {
      return const Size(1000, 1000);
    }

    final ImageStream stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!completer.isCompleted) {
          completer.complete(
            Size(info.image.width.toDouble(), info.image.height.toDouble()),
          );
        }
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete(const Size(1000, 1000));
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  /// Convert a localPosition from inside the Stack (post-transform space)
  /// back to normalized [0,1] image coordinates.
  Offset? _toNormalized(Offset positionInStackLocalSpace) {
    if (_imageKey.currentContext == null) return null;
    final RenderBox imageBox =
        _imageKey.currentContext!.findRenderObject() as RenderBox;
    final Size imageWidgetSize = imageBox.size;

    // Because the GestureDetector is INSIDE the InteractiveViewer's child tree, 
    // positionInStackLocalSpace is already relative to the unzoomed image size.
    // The inverse matrix transformation is not required.
    return Offset(
      (positionInStackLocalSpace.dx / imageWidgetSize.width).clamp(0.0, 1.0),
      (positionInStackLocalSpace.dy / imageWidgetSize.height).clamp(0.0, 1.0),
    );
  }

  void _onDrawStart(DragStartDetails details) {
    final norm = _toNormalized(details.localPosition);
    if (norm == null) return;
    setState(() {
      _dragStartNorm = norm;
      _dragCurrentNorm = norm;
    });
  }

  void _onDrawUpdate(DragUpdateDetails details) {
    final norm = _toNormalized(details.localPosition);
    if (norm == null) return;
    setState(() => _dragCurrentNorm = norm);
  }

  void _onDrawEnd(DragEndDetails _) {
    if (_dragStartNorm == null || _dragCurrentNorm == null) return;
    if (_selectedLabel == null || _selectedLabel!.isEmpty) return;

    final double x1 = _dragStartNorm!.dx;
    final double y1 = _dragStartNorm!.dy;
    final double x2 = _dragCurrentNorm!.dx;
    final double y2 = _dragCurrentNorm!.dy;

    setState(() {
      _dragStartNorm = null;
      _dragCurrentNorm = null;
    });

    // Ignore accidental taps (< 0.5% of image dimension)
    if ((x2 - x1).abs() < 0.005 || (y2 - y1).abs() < 0.005) return;

    setState(() {
      _boundingBoxes.add(BoundingBoxRect(
        x1: x1 < x2 ? x1 : x2,
        y1: y1 < y2 ? y1 : y2,
        x2: x1 < x2 ? x2 : x1,
        y2: y1 < y2 ? y2 : y1,
        label: _selectedLabel!,
      ));
    });
  }

  void _undoLastBox() {
    if (_boundingBoxes.isEmpty) return;
    setState(() => _boundingBoxes.removeLast());
  }

  Future<void> _submitPrototype() async {
    if (_localImageFile == null && _networkImageUrl == null) return;
    final Size originalSize = await _getImageDimensions();

    // Denormalize back to original image pixel coords for the server
    List<Map<String, dynamic>> serverBoxes = _boundingBoxes.map((box) => {
      "label": box.label,
      "x1": box.x1 * originalSize.width,
      "y1": box.y1 * originalSize.height,
      "x2": box.x2 * originalSize.width,
      "y2": box.y2 * originalSize.height,
    }).toList();

    try {
      Dio dio = Dio();
      if (_localImageFile != null) {
        FormData formData = FormData.fromMap({
          "file": await MultipartFile.fromFile(
            _localImageFile!.path, filename: "prototype.jpg",
          ),
          "boxes": jsonEncode(serverBoxes),
        });
        await dio.post(
          '${ApiService.baseUrl}/projects/${widget.project.id}/prototype',
          data: formData,
        );
      } else {
        await dio.put(
          '${ApiService.baseUrl}/projects/${widget.project.id}/boxes',
          data: {"boxes": serverBoxes},
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Layout synchronized successfully'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _pickImage() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() => _isLoading = true);
    _localImageFile = File(picked.path);
    _networkImageUrl = null;
    _boundingBoxes.clear();
    _dragStartNorm = null;
    _dragCurrentNorm = null;
    _transformationController.value = Matrix4.identity();
    final Size dims = await _getImageDimensions();
    setState(() {
      _imageAspect = dims.width / dims.height;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget? imageWidget;
    if (_localImageFile != null) {
      imageWidget = Image.file(_localImageFile!, key: _imageKey, fit: BoxFit.contain);
    } else if (_networkImageUrl != null) {
      imageWidget = Image.network(_networkImageUrl!, key: _imageKey, fit: BoxFit.contain);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Prototype Workspace: ${widget.project.name}'),
        actions: [
          if (imageWidget != null)
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
                    label: const Text('Load Prototype Layout'),
                  ),
                )
              : Column(
                  children: [
                    // Mode toggle
                    Container(
                      color: Colors.grey[200],
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(_isDrawingMode ? Icons.brush : Icons.zoom_out_map, size: 20),
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
                            onChanged: (val) => setState(() => _isDrawingMode = val),
                          ),
                        ],
                      ),
                    ),

                    // Label selector
                    if (_isDrawingMode) _buildLabelSelector(),
                    if (_isDrawingMode && _selectedLabel == null)
                      Container(
                        width: double.infinity,
                        color: Colors.amber[50],
                        padding: const EdgeInsets.all(10),
                        child: const Row(
                          children: [
                            Icon(Icons.info_outline, color: Colors.orange, size: 20),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Select a label above before drawing.',
                                style: TextStyle(fontSize: 13, color: Colors.orange),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Canvas
                    Expanded(
                      child: ClipRect(
                        child: InteractiveViewer(
                          transformationController: _transformationController,
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
                                        imageWidget,

                                        // Boxes overlay - normalized coords
                                        // are converted to screen space
                                        // by the painter using its `size`.
                                        CustomPaint(
                                          painter: CanvasBBoxPainter(
                                            boxes: _boundingBoxes,
                                            dragStartNorm: _dragStartNorm,
                                            dragCurrentNorm: _dragCurrentNorm,
                                            activeLabel: _selectedLabel,
                                          ),
                                        ),

                                        // Drawing gesture surface
                                        if (_isDrawingMode && _selectedLabel != null)
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

                    // Legend
                    if (_boundingBoxes.isNotEmpty) _buildLegend(),

                    // Bottom bar
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange[50]),
                            onPressed: _undoLastBox,
                            icon: const Icon(Icons.undo, color: Colors.orange),
                            label: const Text('Undo Last', style: TextStyle(color: Colors.orange)),
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red[50]),
                            onPressed: () => setState(() => _boundingBoxes.clear()),
                            icon: const Icon(Icons.delete_sweep, color: Colors.red),
                            label: const Text('Clear All', style: TextStyle(color: Colors.red)),
                          ),
                          ElevatedButton.icon(
                            onPressed: _pickImage,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Swap Image'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildLabelSelector() {
    return Container(
      width: double.infinity,
      color: Colors.grey[100],
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Select component label, then draw:',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.black54),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: kAvailableLabels.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final label = kAvailableLabels[index];
                final isSelected = _selectedLabel == label;
                final chipColor = getColorForLabel(label);
                return GestureDetector(
                  onTap: () => setState(() => _selectedLabel = label),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? chipColor.withValues(alpha: 0.85) : Colors.white,
                      border: Border.all(
                        color: isSelected ? chipColor : Colors.grey.shade400,
                        width: isSelected ? 2.5 : 1.0,
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: isSelected
                          ? [BoxShadow(color: chipColor.withValues(alpha: 0.35), blurRadius: 6, offset: const Offset(0, 2))]
                          : [],
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        color: isSelected ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_selectedLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Container(
                    width: 14, height: 14,
                    decoration: BoxDecoration(
                      color: getColorForLabel(_selectedLabel!),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Drawing: $_selectedLabel',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: getColorForLabel(_selectedLabel!)),
                  ),
                  const Spacer(),
                  Text(
                    '${_boundingBoxes.where((b) => b.label == _selectedLabel).length} box(es)',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      width: double.infinity,
      color: Colors.grey[100],
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        children: _boundingBoxes.map((b) => b.label).toSet().map((label) {
          final count = _boundingBoxes.where((b) => b.label == label).length;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 14, height: 14,
                decoration: BoxDecoration(color: getColorForLabel(label), borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 6),
              Text('$label ($count)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          );
        }).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Painter - all coordinates are normalized [0,1]; multiplied by canvas `size`
// at paint time. This means boxes are ALWAYS correct regardless of zoom level.
// ─────────────────────────────────────────────────────────────────────────────
class CanvasBBoxPainter extends CustomPainter {
  final List<BoundingBoxRect> boxes;
  final Offset? dragStartNorm;
  final Offset? dragCurrentNorm;
  final String? activeLabel;

  const CanvasBBoxPainter({
    required this.boxes,
    this.dragStartNorm,
    this.dragCurrentNorm,
    this.activeLabel,
  });

  Offset _toScreen(Offset norm, Size size) =>
      Offset(norm.dx * size.width, norm.dy * size.height);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final box in boxes) {
      paint.color = getColorForLabel(box.label);
      final topLeft = _toScreen(Offset(box.x1, box.y1), size);
      final bottomRight = _toScreen(Offset(box.x2, box.y2), size);
      canvas.drawRect(Rect.fromPoints(topLeft, bottomRight), paint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: ' ${box.label} ',
          style: TextStyle(
            color: getColorForLabel(box.label),
            fontSize: 11,
            fontWeight: FontWeight.bold,
            background: Paint()..color = Colors.black.withValues(alpha: 0.45),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, topLeft);
    }

    // Live preview
    if (dragStartNorm != null && dragCurrentNorm != null) {
      final color = activeLabel != null ? getColorForLabel(activeLabel!) : Colors.blue;
      canvas.drawRect(
        Rect.fromPoints(
          _toScreen(dragStartNorm!, size),
          _toScreen(dragCurrentNorm!, size),
        ),
        Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.0,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CanvasBBoxPainter old) =>
      old.dragStartNorm != dragStartNorm ||
      old.dragCurrentNorm != dragCurrentNorm ||
      old.boxes.length != boxes.length ||
      old.activeLabel != activeLabel;
}