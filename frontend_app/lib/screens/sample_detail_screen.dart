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
  List<String> _uniqueLabels = ['ALL'];
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

  @override
  Widget build(BuildContext context) {
    List<Detection> filteredDetections = widget.sample.detections.where((d) {
      if (_selectedFilter == 'ALL') return true;
      return d.label == _selectedFilter;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Run #${widget.sample.id} Details'),
      ),
      body: Column(
        children: [
          // Filter Dropdown
          Padding(
            padding: const EdgeInsets.all(16.0),
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
                                      detections: filteredDetections,
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

          // List of Filtered Results
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
                      "Detected Components (${filteredDetections.length})",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filteredDetections.length,
                      itemBuilder: (context, index) {
                        final d = filteredDetections[index];
                        return ListTile(
                          title: Text(d.label, style: const TextStyle(fontWeight: FontWeight.bold)),
                          trailing: Text("${(d.conf * 100).toStringAsFixed(1)}%", 
                              style: TextStyle(color: greenAccent, fontWeight: FontWeight.w600)),
                          dense: true,
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
      if (d.label.contains("CAPACITOR")) {
        paint.color = Colors.blue;
      } else {
        paint.color = Colors.redAccent;
      }

      final rect = Rect.fromLTRB(d.bbox[0], d.bbox[1], d.bbox[2], d.bbox[3]);
      canvas.drawRect(rect, paint);
      
      // Draw label background — use cached TextPainter
      final labelText = "${d.label} ${(d.conf * 100).toStringAsFixed(0)}%";
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
