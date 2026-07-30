import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/sample.dart';
import '../services/api_service.dart';

class SampleDetailScreen extends StatefulWidget {
  final Sample sample;
  const SampleDetailScreen({super.key, required this.sample});

  @override
  State<SampleDetailScreen> createState() => _SampleDetailScreenState();
}

class _SampleDetailScreenState extends State<SampleDetailScreen> {
  String _selectedFilter = 'ALL';
  String _presenceFilter = 'ALL'; // 'ALL' | 'PRESENT' | 'MISSING'
  List<String> _uniqueLabels = ['ALL'];
  Detection? _isolatedDetection;
  ui.Image? _uiImage;
  bool _isLoadingImage = true;

  final Color darkBrown = const Color(0xFF291C0E);
  final Color greenAccent = const Color(0xFF6E473B);

  @override
   void initState() {
    super.initState();
    _extractLabels();
    _loadImage();
  }

  void _extractLabels() {
    Set<String> labels = {'ALL'};
    for (var d in widget.sample.detections) {
      labels.add(d.label);
    }
    _uniqueLabels = labels.toList();
  }

  Future<void> _loadImage() async {
    try {
      final String fullUrl = '${ApiService.baseUrl}${widget.sample.originalPath}';
      final Completer<ui.Image> completer = Completer();
      final ImageStream stream = NetworkImage(fullUrl).resolve(const ImageConfiguration());
      stream.addListener(ImageStreamListener((ImageInfo info, bool _) {
        completer.complete(info.image);
      }, onError: (dynamic exception, StackTrace? stackTrace) {
        completer.completeError(exception);
      }));
      _uiImage = await completer.future;
    } catch (e) {
      debugPrint("Failed to load image: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingImage = false;
        });
      }
    }
  }

  static const Map<String, String> _presenceLabels = {
    'ALL': 'All',
    'PRESENT': 'Present',
    'MISSING': 'Missing',
  };

  /// Tapping a detection in the bottom list isolates it in the
  /// visualization (hides every other box); tapping the same one again
  /// restores the normal filtered view.
  void _toggleIsolate(Detection d) {
    setState(() {
      _isolatedDetection = _isolatedDetection == d ? null : d;
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Detection> filteredDetections = widget.sample.detections.where((d) {
      if (_selectedFilter != 'ALL' && d.label != _selectedFilter) return false;
      if (_presenceFilter == 'PRESENT' && d.presence != 'present') return false;
      if (_presenceFilter == 'MISSING' && d.presence != 'missing') return false;
      return true;
    }).toList();

    // An isolated detection takes over the visualization/list entirely,
    // showing just that one box until the user taps it again.
    final List<Detection> displayedDetections =
        _isolatedDetection != null ? [_isolatedDetection!] : filteredDetections;

    return Scaffold(
      appBar: AppBar(
        title: Text('Run #${widget.sample.id} Details'),
      ),
      body: Column(
        children: [
          // Filters
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text("Filter: ", style: TextStyle(fontWeight: FontWeight.bold, color: darkBrown, fontSize: 16)),
                const SizedBox(width: 16),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade400),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedFilter,
                        isExpanded: true,
                        items: _uniqueLabels.map((label) {
                          return DropdownMenuItem<String>(
                            value: label,
                            child: Text(label),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _selectedFilter = val;
                              _isolatedDetection = null;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Rating filter (present / missing, from DINOv2 detection)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Text("Rating: ", style: TextStyle(fontWeight: FontWeight.bold, color: darkBrown, fontSize: 16)),
                const SizedBox(width: 16),
                Expanded(
                  child: SegmentedButton<String>(
                    segments: _presenceLabels.entries
                        .map((e) => ButtonSegment<String>(value: e.key, label: Text(e.value)))
                        .toList(),
                    selected: {_presenceFilter},
                    onSelectionChanged: (sel) {
                      setState(() {
                        _presenceFilter = sel.first;
                        _isolatedDetection = null;
                      });
                    },
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: greenAccent,
                      selectedForegroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Interactive Image Area
          Expanded(
            flex: 2,
            child: Container(
              width: double.infinity,
              color: Colors.black12,
              child: _isLoadingImage
                  ? const Center(child: CircularProgressIndicator())
                  : _uiImage == null
                      ? const Center(child: Text("Failed to load image"))
                      : InteractiveViewer(
                          panEnabled: true,
                          minScale: 1,
                          maxScale: 5,
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.contain,
                              child: SizedBox(
                                width: _uiImage!.width.toDouble(),
                                height: _uiImage!.height.toDouble(),
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    foregroundPainter: BoundingBoxPainter(
                                      detections: displayedDetections,
                                      imageWidth: _uiImage!.width.toDouble(),
                                      imageHeight: _uiImage!.height.toDouble(),
                                    ),
                                    child: RawImage(image: _uiImage),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
            ),
          ),

          // List of Filtered Results — tap one to isolate it in the view above
          Expanded(
            flex: 1,
            child: Container(
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    color: darkBrown,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                    child: Text(
                      _isolatedDetection != null
                          ? "Showing 1 of ${filteredDetections.length} (tap again to reset)"
                          : "Detected Components (${filteredDetections.length})",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filteredDetections.length,
                      itemBuilder: (context, index) {
                        final d = filteredDetections[index];
                        final bool isIsolated = _isolatedDetection == d;
                        return ListTile(
                          selected: isIsolated,
                          selectedTileColor: greenAccent.withAlpha(31),
                          leading: Icon(
                            d.isMissing ? Icons.error_outline : Icons.check_circle_outline,
                            color: d.isMissing ? Colors.redAccent : Colors.green,
                          ),
                          title: Text(d.displayLabel,
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: d.isMissing ? const Text('MISSING', style: TextStyle(color: Colors.redAccent)) : null,
                          trailing: Text("${(d.conf * 100).toStringAsFixed(1)}%",
                              style: TextStyle(color: greenAccent, fontWeight: FontWeight.w600)),
                          dense: true,
                          onTap: () => _toggleIsolate(d),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BoundingBoxPainter extends CustomPainter {
  final List<Detection> detections;
  final double imageWidth;
  final double imageHeight;

  // Cache TextPainters to avoid rebuilding the glyph atlas every frame
  final Map<String, TextPainter> _labelPainterCache = {};

  BoundingBoxPainter({
    required this.detections,
    required this.imageWidth,
    required this.imageHeight,
  });

  TextPainter _getOrCreateLabelPainter(String text) {
    return _labelPainterCache.putIfAbsent(text, () {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      return tp;
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Because we wrapped CustomPaint in a SizedBox of the exact image dimensions
    // and scaled it down with FittedBox, the size here is exactly imageWidth x imageHeight.
    // So coordinates are 1:1 with the original image pixels!

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    for (var d in detections) {
      paint.color = d.isMissing ? Colors.redAccent : Colors.greenAccent.shade400;

      final rect = Rect.fromLTRB(d.bbox[0], d.bbox[1], d.bbox[2], d.bbox[3]);
      canvas.drawRect(rect, paint);

      // Draw label background — use cached TextPainter
      final labelText = d.isMissing ? "MISSING ${d.label}" : d.displayLabel;
      final textPainter = _getOrCreateLabelPainter(labelText);

      final labelBgRect = Rect.fromLTWH(
        rect.left,
        rect.top - textPainter.height,
        textPainter.width + 4,
        textPainter.height
      );

      final bgPaint = Paint()..color = paint.color..style = PaintingStyle.fill;
      canvas.drawRect(labelBgRect, bgPaint);

      textPainter.paint(canvas, Offset(rect.left + 2, rect.top - textPainter.height));
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) {
    return true; // Simple approach: always repaint on filter change
  }
}
