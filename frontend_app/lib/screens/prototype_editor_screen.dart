// lib/screens/prototype_editor_screen.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'dart:convert';
import '../models/project.dart';
import '../services/api_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DATA MODEL  (unchanged from original)
// ─────────────────────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────────────────────
// RESIZE HANDLE
// ─────────────────────────────────────────────────────────────────────────────

enum _ResizeHandle { topLeft, topRight, bottomLeft, bottomRight, none }

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class PrototypeEditorScreen extends StatefulWidget {
  final Project project;
  const PrototypeEditorScreen({super.key, required this.project});

  @override
  State<PrototypeEditorScreen> createState() => _PrototypeEditorScreenState();
}

class _PrototypeEditorScreenState extends State<PrototypeEditorScreen> {
  // ── image state ─────────────────────────────────────────────────────────────
  File? _localImageFile;
  String? _networkImageUrl;
  double? _imageAspect;

  // ── boxes ───────────────────────────────────────────────────────────────────
  final List<BoundingBoxRect> _boundingBoxes = [];

  // ── live draw — normalized [0,1] (original logic, untouched) ────────────────
  Offset? _dragStartNorm;
  Offset? _dragCurrentNorm;

  // ── selection / resize ──────────────────────────────────────────────────────
  int? _selectedBoxIndex;
  _ResizeHandle _activeHandle = _ResizeHandle.none;

  // ── services / keys ─────────────────────────────────────────────────────────
  final ImagePicker _picker = ImagePicker();
  final _imageKey = GlobalKey();
  final TransformationController _transformationController =
      TransformationController();

  // ── ui state ────────────────────────────────────────────────────────────────
  // _isDrawingMode == true  → a label is selected, finger draws a new box
  // _isDrawingMode == false → InteractiveViewer owns pinch/pan; tap selects box
  bool _isDrawingMode = false;
  bool _isLoading = false;
  String? _selectedLabel;

  // ── labels — base list + any custom labels added this session/loaded ───────
  final List<String> _labels = List<String>.from(kAvailableLabels);

  void _addLabelIfNew(String label) {
    final exists = _labels.any((l) => l.toLowerCase() == label.toLowerCase());
    if (!exists) _labels.add(label);
  }

  // ── debug ───────────────────────────────────────────────────────────────────
  bool _showDebugPanel = false;
  final List<String> _debugLog = [];

  void _log(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    debugPrint('[PCB $ts] $msg');
    if (mounted) {
      setState(() {
        _debugLog.insert(0, '[$ts] $msg');
        if (_debugLog.length > 150) _debugLog.removeLast();
      });
    }
  }

  // ── lifecycle ────────────────────────────────────────────────────────────────

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

  // ─────────────────────────────────────────────────────────────────────────────
  // NETWORK / DATA  (all original logic, debug logs added only)
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _initializePrototypeData() async {
    if (widget.project.prototypePath != null &&
        widget.project.prototypePath!.isNotEmpty) {
      setState(() => _isLoading = true);
      _networkImageUrl =
          '${ApiService.baseUrl}/${widget.project.prototypePath}';
      _log('Network image URL: $_networkImageUrl');
      final Size dims = await _getImageDimensions();
      _imageAspect = dims.width / dims.height;
      _log('Image dims: ${dims.width}x${dims.height}  aspect=$_imageAspect');
      await _fetchExistingBoxes();
    }
  }

  Future<void> _fetchExistingBoxes() async {
    _log('Fetching boxes from server…');
    try {
      Dio dio = Dio();
      Response response = await dio.get(
        '${ApiService.baseUrl}/projects/${widget.project.id}/boxes',
      );
      if (response.statusCode == 200 && response.data != null) {
        final Size originalSize = await _getImageDimensions();
        final List<dynamic> fetched = response.data;
        _log('Server returned ${fetched.length} box(es)  '
            'normalising with ${originalSize.width}x${originalSize.height}');
        setState(() {
          _boundingBoxes.clear();
          for (var box in fetched) {
            final double nx1 = (box['x1'] as num) / originalSize.width;
            final double ny1 = (box['y1'] as num) / originalSize.height;
            final double nx2 = (box['x2'] as num) / originalSize.width;
            final double ny2 = (box['y2'] as num) / originalSize.height;
            final String label = box['label'] ?? 'target_component';
            _log('  box label=$label  '
                'px=(${box['x1']},${box['y1']},${box['x2']},${box['y2']}) '
                '→ norm=($nx1,$ny1,$nx2,$ny2)');
            _boundingBoxes.add(BoundingBoxRect(
              x1: nx1, y1: ny1, x2: nx2, y2: ny2,
              label: label,
            ));
            // Surface any pre-existing custom label as a selectable chip
            _addLabelIfNew(label);
          }
        });
      }
    } catch (e) {
      _log('ERROR fetching boxes: $e');
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

  // ─────────────────────────────────────────────────────────────────────────────
  // COORDINATE HELPER  (original, untouched)
  // ─────────────────────────────────────────────────────────────────────────────

  /// Converts a localPosition from inside the Stack back to normalised [0,1].
  /// The GestureDetector lives INSIDE the InteractiveViewer child tree so
  /// localPosition is already in unscaled image space — no matrix inversion needed.
  Offset? _toNormalized(Offset localPos) {
    if (_imageKey.currentContext == null) return null;
    final RenderBox box =
        _imageKey.currentContext!.findRenderObject() as RenderBox;
    final Size sz = box.size;
    return Offset(
      (localPos.dx / sz.width).clamp(0.0, 1.0),
      (localPos.dy / sz.height).clamp(0.0, 1.0),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // DRAW GESTURES  (original logic, untouched — only called when _isDrawingMode)
  // ─────────────────────────────────────────────────────────────────────────────

  void _onDrawStart(DragStartDetails d) {
    final norm = _toNormalized(d.localPosition);
    if (norm == null) return;
    _log('Draw start norm=(${norm.dx.toStringAsFixed(4)},${norm.dy.toStringAsFixed(4)})');
    setState(() { _dragStartNorm = norm; _dragCurrentNorm = norm; });
  }

  void _onDrawUpdate(DragUpdateDetails d) {
    final norm = _toNormalized(d.localPosition);
    if (norm == null) return;
    setState(() => _dragCurrentNorm = norm);
  }

  void _onDrawEnd(DragEndDetails _) {
    if (_dragStartNorm == null || _dragCurrentNorm == null) return;
    if (_selectedLabel == null || _selectedLabel!.isEmpty) return;

    final double x1 = _dragStartNorm!.dx, y1 = _dragStartNorm!.dy;
    final double x2 = _dragCurrentNorm!.dx, y2 = _dragCurrentNorm!.dy;

    setState(() { _dragStartNorm = null; _dragCurrentNorm = null; });

    // Ignore accidental taps (< 0.5 % of image dimension)
    if ((x2 - x1).abs() < 0.005 || (y2 - y1).abs() < 0.005) {
      _log('Draw ignored — too small');
      return;
    }

    final double fx1 = x1 < x2 ? x1 : x2, fy1 = y1 < y2 ? y1 : y2;
    final double fx2 = x1 < x2 ? x2 : x1, fy2 = y1 < y2 ? y2 : y1;
    _log('Box drawn label=$_selectedLabel norm=($fx1,$fy1,$fx2,$fy2)');
    setState(() {
      _boundingBoxes.add(BoundingBoxRect(
        x1: fx1, y1: fy1, x2: fx2, y2: fy2, label: _selectedLabel!,
      ));
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // SELECT / RESIZE GESTURES
  //
  // KEY DESIGN:
  //   • In NAVIGATE mode  (_isDrawingMode == false):
  //       InteractiveViewer owns pinch-zoom and pan.
  //       We use a Listener (pointer-down only, no gesture arena competition)
  //       to detect tap-on-box for selection and tap-on-handle for resize.
  //       A separate GestureDetector handles the resize drag while a handle
  //       is active; otherwise the InteractiveViewer handles the drag.
  //
  //   • In DRAW mode (_isDrawingMode == true):
  //       InteractiveViewer pan/scale are DISABLED.
  //       A GestureDetector sits over the canvas and drives _onDrawStart/
  //       Update/End exactly as in the original code.
  //
  // This separation is what fixes both bugs:
  //   Bug 1 (no zoom): the GestureDetector in the previous version captured
  //     every pan gesture in both modes, so InteractiveViewer never got them.
  //   Bug 2 (no selection): selection only happened when _isDrawingMode==false
  //     AND no label was active, but the GestureDetector ate the gesture first.
  // ─────────────────────────────────────────────────────────────────────────────

  static const double _handleHitNorm = 0.030; // 3 % of image — fingertip friendly

  _ResizeHandle _hitTestHandle(BoundingBoxRect b, Offset n) {
    bool near(double a, double v) => (a - v).abs() < _handleHitNorm;
    if (near(n.dx, b.x1) && near(n.dy, b.y1)) return _ResizeHandle.topLeft;
    if (near(n.dx, b.x2) && near(n.dy, b.y1)) return _ResizeHandle.topRight;
    if (near(n.dx, b.x1) && near(n.dy, b.y2)) return _ResizeHandle.bottomLeft;
    if (near(n.dx, b.x2) && near(n.dy, b.y2)) return _ResizeHandle.bottomRight;
    return _ResizeHandle.none;
  }

  int _hitTestBox(Offset n) {
    // Iterate newest-first so the top-most box wins
    for (int i = _boundingBoxes.length - 1; i >= 0; i--) {
      final b = _boundingBoxes[i];
      if (n.dx >= b.x1 && n.dx <= b.x2 && n.dy >= b.y1 && n.dy <= b.y2) {
        return i;
      }
    }
    return -1;
  }

  // Called by Listener.onPointerDown — runs BEFORE the gesture arena resolves,
  // so it never blocks InteractiveViewer from claiming a pinch/scale gesture.
  void _onPointerDown(PointerDownEvent event) {
    if (_isDrawingMode) return; // draw mode: GestureDetector handles everything

    final norm = _toNormalized(event.localPosition);
    if (norm == null) return;

    // Check handles first (only if something is already selected)
    if (_selectedBoxIndex != null) {
      final handle = _hitTestHandle(_boundingBoxes[_selectedBoxIndex!], norm);
      if (handle != _ResizeHandle.none) {
        _log('Handle hit: $handle on box[$_selectedBoxIndex]');
        setState(() => _activeHandle = handle);
        return; // GestureDetector below will handle the drag
      }
    }

    // Tap on a box → select it
    final idx = _hitTestBox(norm);
    _log(idx >= 0
        ? 'Selected box[$idx] label=${_boundingBoxes[idx].label}'
        : 'Tapped empty → deselect');
    setState(() {
      _selectedBoxIndex = idx >= 0 ? idx : null;
      _activeHandle = _ResizeHandle.none;
    });
  }

  // Resize drag — driven by the GestureDetector that wraps the whole canvas
  // in navigate mode, but only does work when _activeHandle != none.
  void _onResizePanUpdate(DragUpdateDetails d) {
    if (_activeHandle == _ResizeHandle.none || _selectedBoxIndex == null) return;
    final norm = _toNormalized(d.localPosition);
    if (norm == null) return;
    setState(() {
      final b = _boundingBoxes[_selectedBoxIndex!];
      switch (_activeHandle) {
        case _ResizeHandle.topLeft:
          b.x1 = norm.dx.clamp(0.0, b.x2 - 0.01);
          b.y1 = norm.dy.clamp(0.0, b.y2 - 0.01);
        case _ResizeHandle.topRight:
          b.x2 = norm.dx.clamp(b.x1 + 0.01, 1.0);
          b.y1 = norm.dy.clamp(0.0, b.y2 - 0.01);
        case _ResizeHandle.bottomLeft:
          b.x1 = norm.dx.clamp(0.0, b.x2 - 0.01);
          b.y2 = norm.dy.clamp(b.y1 + 0.01, 1.0);
        case _ResizeHandle.bottomRight:
          b.x2 = norm.dx.clamp(b.x1 + 0.01, 1.0);
          b.y2 = norm.dy.clamp(b.y1 + 0.01, 1.0);
        case _ResizeHandle.none:
          break;
      }
    });
  }

  void _onResizePanEnd(DragEndDetails _) {
    if (_activeHandle == _ResizeHandle.none) return;
    if (_selectedBoxIndex != null) {
      final b = _boundingBoxes[_selectedBoxIndex!];
      _log('Resize END box[$_selectedBoxIndex] '
          'norm=(${b.x1.toStringAsFixed(4)},${b.y1.toStringAsFixed(4)},'
          '${b.x2.toStringAsFixed(4)},${b.y2.toStringAsFixed(4)})');
    }
    setState(() => _activeHandle = _ResizeHandle.none);
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // EDIT ACTIONS
  // ─────────────────────────────────────────────────────────────────────────────

  void _undoLastBox() {
    if (_boundingBoxes.isEmpty) return;
    _log('Undo — removed box[${_boundingBoxes.length - 1}] label=${_boundingBoxes.last.label}');
    setState(() {
      if (_selectedBoxIndex == _boundingBoxes.length - 1) _selectedBoxIndex = null;
      _boundingBoxes.removeLast();
    });
  }

  void _deleteSelectedBox() {
    if (_selectedBoxIndex == null) return;
    _log('Delete box[$_selectedBoxIndex] label=${_boundingBoxes[_selectedBoxIndex!].label}');
    setState(() {
      _boundingBoxes.removeAt(_selectedBoxIndex!);
      _selectedBoxIndex = null;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // SUBMIT  (original serialisation logic, debug logs added around it)
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _submitPrototype() async {
    if (_localImageFile == null && _networkImageUrl == null) return;
    final Size originalSize = await _getImageDimensions();

    _log('=== SUBMIT START ===');
    _log('Denormalising ${_boundingBoxes.length} box(es) '
        'using image size ${originalSize.width}x${originalSize.height}');

    // Denormalise back to original pixel coords for the server — ORIGINAL LOGIC
    List<Map<String, dynamic>> serverBoxes =
        _boundingBoxes.asMap().entries.map((e) {
      final i = e.key;
      final box = e.value;
      final px1 = box.x1 * originalSize.width;
      final py1 = box.y1 * originalSize.height;
      final px2 = box.x2 * originalSize.width;
      final py2 = box.y2 * originalSize.height;
      _log('  [$i] label=${box.label} '
          'norm=(${box.x1.toStringAsFixed(4)},${box.y1.toStringAsFixed(4)},'
          '${box.x2.toStringAsFixed(4)},${box.y2.toStringAsFixed(4)}) '
          '→ px=(${px1.toStringAsFixed(1)},${py1.toStringAsFixed(1)},'
          '${px2.toStringAsFixed(1)},${py2.toStringAsFixed(1)})');
      return {"label": box.label, "x1": px1, "y1": py1, "x2": px2, "y2": py2};
    }).toList();

    final String jsonPayload = jsonEncode(serverBoxes);
    _log('JSON payload → server:\n$jsonPayload');

    try {
      Dio dio = Dio();
      if (_localImageFile != null) {
        _log('POST multipart (local image + boxes)');
        FormData formData = FormData.fromMap({
          "file": await MultipartFile.fromFile(
              _localImageFile!.path, filename: 'prototype.jpg'),
          "boxes": jsonPayload,
        });
        await dio.post(
          '${ApiService.baseUrl}/projects/${widget.project.id}/prototype',
          data: formData,
        );
      } else {
        _log('PUT boxes only (image already on server)');
        await dio.put(
          '${ApiService.baseUrl}/projects/${widget.project.id}/boxes',
          data: {"boxes": serverBoxes},
        );
      }
      _log('=== SUBMIT SUCCESS ===');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Layout synchronized successfully'),
        backgroundColor: Colors.green,
      ));
      Navigator.pop(context);
    } catch (e) {
      _log('=== SUBMIT ERROR: $e ===');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // IMAGE PICKER  (original logic, untouched)
  // ─────────────────────────────────────────────────────────────────────────────

  /// Shows a bottom sheet letting the user pick Camera or Gallery as the
  /// image source. Returns null if the user dismisses without choosing.
  Future<ImageSource?> _pickImageSource() {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Colors.white70),
                title: const Text('Take Photo',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.white70),
                title: const Text('Choose from Gallery',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickImage() async {
    final ImageSource? source = await _pickImageSource();
    if (source == null) return;
    final XFile? picked = await _picker.pickImage(source: source);
    if (picked == null) return;
    setState(() => _isLoading = true);
    _localImageFile = File(picked.path);
    _networkImageUrl = null;
    _boundingBoxes.clear();
    _dragStartNorm = null;
    _dragCurrentNorm = null;
    _selectedBoxIndex = null;
    _activeHandle = _ResizeHandle.none;
    _transformationController.value = Matrix4.identity();
    final Size dims = await _getImageDimensions();
    _log('Image picked: ${picked.path}  dims=${dims.width}x${dims.height}');
    setState(() {
      _imageAspect = dims.width / dims.height;
      _isLoading = false;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    Widget? imageWidget;
    if (_localImageFile != null) {
      imageWidget = Image.file(_localImageFile!, key: _imageKey, fit: BoxFit.contain);
    } else if (_networkImageUrl != null) {
      imageWidget = Image.network(_networkImageUrl!, key: _imageKey, fit: BoxFit.contain);
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0E1117),
      appBar: _buildAppBar(imageWidget != null),
      body: _isLoading
          ? _buildLoader()
          : imageWidget == null
              ? _buildEmptyState()
              : _buildWorkspace(imageWidget),
    );
  }

  // ── AppBar ───────────────────────────────────────────────────────────────────

  AppBar _buildAppBar(bool hasImage) {
    return AppBar(
      backgroundColor: const Color(0xFF161B22),
      foregroundColor: Colors.white,
      elevation: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.project.name,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
          Text('PCB Annotation Workspace',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.4),
                  letterSpacing: 0.5)),
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.bug_report_outlined,
              color: _showDebugPanel
                  ? const Color(0xFF58A6FF)
                  : Colors.white54),
          tooltip: 'Debug panel',
          onPressed: () => setState(() => _showDebugPanel = !_showDebugPanel),
        ),
        if (hasImage)
          IconButton(
            icon: const Icon(Icons.cloud_upload_outlined,
                color: Color(0xFF3FB950)),
            tooltip: 'Sync to server',
            onPressed: _submitPrototype,
          ),
      ],
    );
  }

  // ── Loader / empty ───────────────────────────────────────────────────────────

  Widget _buildLoader() => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF58A6FF)),
            SizedBox(height: 16),
            Text('Loading prototype…',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      );

  Widget _buildEmptyState() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: const Icon(Icons.developer_board,
                  size: 36, color: Color(0xFF58A6FF)),
            ),
            const SizedBox(height: 20),
            const Text('No prototype image loaded',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Load a PCB image to start annotating',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35), fontSize: 13)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF238636),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: _pickImage,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Load PCB Image'),
            ),
          ],
        ),
      );

  // ── Main workspace ───────────────────────────────────────────────────────────

  Widget _buildWorkspace(Widget imageWidget) {
    return Column(
      children: [
        _buildModeStatusBar(),
        Expanded(child: _buildCanvas(imageWidget)),
        if (_showDebugPanel) _buildDebugPanel(),
        _buildBottomPanel(),
      ],
    );
  }

  // ── Mode status bar ──────────────────────────────────────────────────────────

  Widget _buildModeStatusBar() {
    final Color accent = _isDrawingMode
        ? getColorForLabel(_selectedLabel ?? 'resistor')
        : _selectedBoxIndex != null
            ? const Color(0xFF79C0FF)
            : const Color(0xFF58A6FF);

    final String statusText = _isDrawingMode
        ? 'Draw mode  ·  $_selectedLabel  ·  drag to annotate'
        : _selectedBoxIndex != null
            ? 'Selected: ${_boundingBoxes[_selectedBoxIndex!].label}  ·  drag corner handle to resize'
            : 'Navigate  ·  pinch to zoom  ·  tap a label to annotate';

    return Container(
      height: 34,
      color: const Color(0xFF161B22),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: accent.withValues(alpha: 0.55), blurRadius: 5)
              ],
            ),
          ),
          const SizedBox(width: 9),
          Text(statusText,
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.65),
                  letterSpacing: 0.1)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
                '${_boundingBoxes.length} box${_boundingBoxes.length == 1 ? '' : 'es'}',
                style:
                    const TextStyle(fontSize: 11, color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  // ── Canvas ───────────────────────────────────────────────────────────────────
  //
  // GESTURE ARCHITECTURE (fixes both bugs):
  //
  //  ┌─ InteractiveViewer (panEnabled & scaleEnabled = !_isDrawingMode) ───────┐
  //  │  ┌─ Listener (onPointerDown — no gesture arena) ──────────────────────┐ │
  //  │  │  ┌─ GestureDetector ─────────────────────────────────────────────┐ │ │
  //  │  │  │  AspectRatio → Stack                                          │ │ │
  //  │  │  │    Image (key=_imageKey)                                      │ │ │
  //  │  │  │    CustomPaint (boxes + handles)                              │ │ │
  //  │  │  └───────────────────────────────────────────────────────────────┘ │ │
  //  │  └────────────────────────────────────────────────────────────────────┘ │
  //  └────────────────────────────────────────────────────────────────────────┘
  //
  //  Navigate mode (_isDrawingMode == false):
  //    - InteractiveViewer handles pinch-zoom and pan  ← zoom restored
  //    - Listener.onPointerDown fires first (no arena) → sets _selectedBoxIndex
  //      and _activeHandle without blocking InteractiveViewer  ← selection fixed
  //    - GestureDetector.onPanUpdate/End → drives resize when _activeHandle≠none
  //      (a single-finger drag while a handle is active won't be claimed by IV
  //       because IV's panEnabled is still true, but in practice the user is
  //       touching a tiny handle, so the delta is small and IV treats it as zoom).
  //       To guarantee resize wins we set panEnabled = !(_isDrawingMode || _activeHandle != none).
  //
  //  Draw mode (_isDrawingMode == true):
  //    - InteractiveViewer pan+scale DISABLED
  //    - GestureDetector owns pan → _onDrawStart/Update/End (original logic)

  Widget _buildCanvas(Widget imageWidget) {
    final Stack canvas = Stack(
      fit: StackFit.expand,
      children: [
        imageWidget,
        CustomPaint(
          painter: CanvasBBoxPainter(
            boxes: _boundingBoxes,
            dragStartNorm: _dragStartNorm,
            dragCurrentNorm: _dragCurrentNorm,
            activeLabel: _selectedLabel,
            selectedIndex: _selectedBoxIndex,
          ),
        ),
      ],
    );

    // CRITICAL: Only wrap in a GestureDetector (which competes in the gesture
    // arena and can block InteractiveViewer's pinch-zoom) when we actually need
    // it — i.e., when drawing a box or actively resizing one.
    // In pure navigate mode, use only the Listener (which is passive and NEVER
    // blocks InteractiveViewer), so pinch-to-zoom always works.
    final bool needsGestureDetector =
        _isDrawingMode || _activeHandle != _ResizeHandle.none;

    Widget inner = needsGestureDetector
        ? GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: _isDrawingMode ? _onDrawStart : null,
            onPanUpdate: _isDrawingMode
                ? _onDrawUpdate
                : (_activeHandle != _ResizeHandle.none
                    ? _onResizePanUpdate
                    : null),
            onPanEnd: _isDrawingMode
                ? _onDrawEnd
                : (_activeHandle != _ResizeHandle.none
                    ? _onResizePanEnd
                    : null),
            onPanCancel: () {
              if (mounted) {
                setState(() {
                  _dragStartNorm = null;
                  _dragCurrentNorm = null;
                });
              }
            },
            child: canvas,
          )
        : canvas;

    // Listener is always passive — it never blocks InteractiveViewer.
    inner = Listener(
      onPointerDown: _onPointerDown,
      child: inner,
    );

    return Container(
      color: const Color(0xFF0D1117),
      child: ClipRect(
        child: InteractiveViewer(
          transformationController: _transformationController,
          panEnabled: !_isDrawingMode && _activeHandle == _ResizeHandle.none,
          scaleEnabled: true,  // pinch-zoom ALWAYS on
          minScale: 0.5,
          maxScale: 20.0,
          child: _imageAspect == null
              ? const SizedBox()
              : Center(
                  child: AspectRatio(
                    aspectRatio: _imageAspect!,
                    child: inner,
                  ),
                ),
        ),
      ),
    );
  }

  // ── Bottom panel ─────────────────────────────────────────────────────────────

  Widget _buildBottomPanel() {
    return Container(
      color: const Color(0xFF161B22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, color: Color(0xFF30363D)),
          _buildLabelStrip(),
          const Divider(height: 1, color: Color(0xFF30363D)),
          _buildActionRow(),
        ],
      ),
    );
  }

  // ── Label strip ──────────────────────────────────────────────────────────────
  // Chips show label + live count; tapping selects/deselects (draw mode toggle)

  Widget _buildLabelStrip() {
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        itemCount: _labels.length + 1, // +1 for the "add custom label" chip
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          if (index == _labels.length) {
            return GestureDetector(
              onTap: _showAddCustomLabelDialog,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF21262D),
                  border: Border.all(
                      color: const Color(0xFF58A6FF), width: 1.0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 14, color: Color(0xFF58A6FF)),
                    SizedBox(width: 4),
                    Text('Custom label',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF58A6FF))),
                  ],
                ),
              ),
            );
          }

          final label = _labels[index];
          final isSelected = _selectedLabel == label;
          final chipColor = getColorForLabel(label);
          final count = _boundingBoxes.where((b) => b.label == label).length;

          return GestureDetector(
            onTap: () {
              setState(() {
                if (_selectedLabel == label) {
                  // Toggle off → navigate mode
                  _selectedLabel = null;
                  _isDrawingMode = false;
                  _log('Label deselected → navigate mode');
                } else {
                  _selectedLabel = label;
                  _isDrawingMode = true;
                  _selectedBoxIndex = null;
                  _activeHandle = _ResizeHandle.none;
                  _log('Label selected: $label → draw mode');
                }
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: isSelected
                    ? chipColor.withValues(alpha: 0.20)
                    : const Color(0xFF21262D),
                border: Border.all(
                  color: isSelected ? chipColor : const Color(0xFF30363D),
                  width: isSelected ? 1.5 : 1.0,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(
                        color: chipColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    count > 0 ? '$label ($count)' : label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.w500,
                      color:
                          isSelected ? Colors.white : Colors.white60,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Custom label dialog ──────────────────────────────────────────────────────

  Future<void> _showAddCustomLabelDialog() async {
    final TextEditingController controller = TextEditingController();
    final String? newLabel = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: const Text('Add Custom Label',
              style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'e.g. fuse, ferrite bead...',
              hintStyle: TextStyle(color: Colors.white38),
            ),
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.pop(context, controller.text.trim()),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    if (newLabel == null || newLabel.isEmpty) return;

    _log('Custom label added: $newLabel');
    setState(() {
      _addLabelIfNew(newLabel);
      _selectedLabel = newLabel;
      _isDrawingMode = true;
      _selectedBoxIndex = null;
      _activeHandle = _ResizeHandle.none;
    });
  }

  // ── Action row ───────────────────────────────────────────────────────────────

  Widget _buildActionRow() {
    final bool hasSelected = _selectedBoxIndex != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Row(
        children: [
          _actionBtn(
            icon: Icons.undo_rounded,
            label: 'Undo',
            color: const Color(0xFFD29922),
            onTap: _undoLastBox,
          ),
          const SizedBox(width: 8),
          _actionBtn(
            icon: Icons.delete_sweep_rounded,
            label: 'Clear All',
            color: const Color(0xFFF85149),
            onTap: () {
              _log('Clear all — ${_boundingBoxes.length} box(es) removed');
              setState(() {
                _boundingBoxes.clear();
                _selectedBoxIndex = null;
              });
            },
          ),
          const SizedBox(width: 8),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: hasSelected ? 1.0 : 0.3,
            child: _actionBtn(
              icon: Icons.highlight_remove_rounded,
              label: 'Delete Box',
              color: const Color(0xFFFF7B72),
              onTap: hasSelected ? _deleteSelectedBox : null,
            ),
          ),
          const Spacer(),
          _actionBtn(
            icon: Icons.swap_horiz_rounded,
            label: 'Swap',
            color: const Color(0xFF58A6FF),
            onTap: _pickImage,
          ),
        ],
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: color.withValues(alpha: 0.28), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // ── Debug panel ──────────────────────────────────────────────────────────────

  Widget _buildDebugPanel() {
    return Container(
      height: 210,
      color: const Color(0xFF0D1117),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            color: const Color(0xFF161B22),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 14, color: Color(0xFF3FB950)),
                const SizedBox(width: 6),
                const Text('Debug Log',
                    style: TextStyle(
                        color: Color(0xFF3FB950),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace')),
                const Spacer(),
                GestureDetector(
                  onTap: _logCoordSnapshot,
                  child: const Text('COORD SNAPSHOT',
                      style: TextStyle(
                          color: Color(0xFF58A6FF),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5)),
                ),
                const SizedBox(width: 14),
                GestureDetector(
                  onTap: () => setState(() => _debugLog.clear()),
                  child: const Text('CLEAR',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5)),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              itemCount: _debugLog.length,
              itemBuilder: (_, i) => Text(
                _debugLog[i],
                style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF8B949E),
                    fontFamily: 'monospace',
                    height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Full coordinate snapshot — shows normalised → pixel → JSON for every box.
  Future<void> _logCoordSnapshot() async {
    final Size sz = await _getImageDimensions();
    _log('──── COORDINATE SNAPSHOT ────');
    _log('Image pixel size: ${sz.width}x${sz.height}');
    _log('Boxes: ${_boundingBoxes.length}');
    for (int i = 0; i < _boundingBoxes.length; i++) {
      final b = _boundingBoxes[i];
      _log('[$i] label=${b.label}');
      _log('    norm  x1=${b.x1.toStringAsFixed(5)} y1=${b.y1.toStringAsFixed(5)} '
          'x2=${b.x2.toStringAsFixed(5)} y2=${b.y2.toStringAsFixed(5)}');
      _log('    px    x1=${(b.x1 * sz.width).toStringAsFixed(1)} '
          'y1=${(b.y1 * sz.height).toStringAsFixed(1)} '
          'x2=${(b.x2 * sz.width).toStringAsFixed(1)} '
          'y2=${(b.y2 * sz.height).toStringAsFixed(1)}');
    }
    final preview = _boundingBoxes
        .map((b) => {
              "label": b.label,
              "x1": b.x1 * sz.width,
              "y1": b.y1 * sz.height,
              "x2": b.x2 * sz.width,
              "y2": b.y2 * sz.height,
            })
        .toList();
    _log('JSON → server:\n${const JsonEncoder.withIndent('  ').convert(preview)}');
    _log('─────────────────────────────');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PAINTER
// All coordinate math is original and untouched.
// Visual changes only: stroke 1.2, faint fill, corner handles on selection.
// ─────────────────────────────────────────────────────────────────────────────

class CanvasBBoxPainter extends CustomPainter {
  final List<BoundingBoxRect> boxes;
  final Offset? dragStartNorm;
  final Offset? dragCurrentNorm;
  final String? activeLabel;
  final int? selectedIndex;

  const CanvasBBoxPainter({
    required this.boxes,
    this.dragStartNorm,
    this.dragCurrentNorm,
    this.activeLabel,
    this.selectedIndex,
  });

  // Original helper — untouched
  Offset _toScreen(Offset norm, Size size) =>
      Offset(norm.dx * size.width, norm.dy * size.height);

  @override
  void paint(Canvas canvas, Size size) {
    final strokePaint = Paint()..style = PaintingStyle.stroke;

    for (int i = 0; i < boxes.length; i++) {
      final box = boxes[i];
      final color = getColorForLabel(box.label);
      final topLeft = _toScreen(Offset(box.x1, box.y1), size);
      final bottomRight = _toScreen(Offset(box.x2, box.y2), size);
      final rect = Rect.fromPoints(topLeft, bottomRight);
      final bool sel = i == selectedIndex;

      // Faint fill
      canvas.drawRect(rect,
          Paint()
            ..color = color.withValues(alpha: sel ? 0.13 : 0.05)
            ..style = PaintingStyle.fill);

      // Border — 1.2 px (1.8 when selected)
      canvas.drawRect(rect,
          strokePaint
            ..color = sel ? color : color.withValues(alpha: 0.7)
            ..strokeWidth = sel ? 1.8 : 1.2);

      // Label tag
      final tp = TextPainter(
        text: TextSpan(
          text: ' ${box.label} ',
          style: TextStyle(
            color: Colors.white,
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            background: Paint()..color = color.withValues(alpha: 0.80),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, topLeft);

      // Corner handles (only on selected box)
      if (sel) {
        _handle(canvas, topLeft, color);
        _handle(canvas, Offset(bottomRight.dx, topLeft.dy), color);
        _handle(canvas, Offset(topLeft.dx, bottomRight.dy), color);
        _handle(canvas, bottomRight, color);
      }
    }

    // Live preview
    if (dragStartNorm != null && dragCurrentNorm != null) {
      final color =
          activeLabel != null ? getColorForLabel(activeLabel!) : Colors.blueAccent;
      final r = Rect.fromPoints(
          _toScreen(dragStartNorm!, size), _toScreen(dragCurrentNorm!, size));
      canvas.drawRect(r,
          Paint()
            ..color = color.withValues(alpha: 0.07)
            ..style = PaintingStyle.fill);
      canvas.drawRect(r,
          Paint()
            ..color = color.withValues(alpha: 0.65)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
    }
  }

  void _handle(Canvas canvas, Offset c, Color color) {
    canvas.drawCircle(c, 5.0,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill);
    canvas.drawCircle(c, 5.0,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant CanvasBBoxPainter old) =>
      old.dragStartNorm != dragStartNorm ||
      old.dragCurrentNorm != dragCurrentNorm ||
      old.boxes.length != boxes.length ||
      old.activeLabel != activeLabel ||
      old.selectedIndex != selectedIndex;
}
