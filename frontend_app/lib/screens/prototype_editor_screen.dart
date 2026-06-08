// lib/screens/prototype_editor_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'dart:ui' as ui;
import 'dart:convert'; // Required for jsonEncode
import '../models/project.dart';
import '../services/api_service.dart';

class BoundingBoxRect {
  Offset start;
  Offset end;
  String label; // Track custom labels for your components
  BoundingBoxRect({required this.start, required this.end, required this.label});
}

class PrototypeEditorScreen extends StatefulWidget {
  final Project project;
  const PrototypeEditorScreen({super.key, required this.project});

  @override
  State<PrototypeEditorScreen> createState() => _PrototypeEditorScreenState();
}

class _PrototypeEditorScreenState extends State<PrototypeEditorScreen> {
  File? _imageFile;
  final List<BoundingBoxRect> _boundingBoxes = [];
  BoundingBoxRect? _currentBox;
  final ImagePicker _picker = ImagePicker();
  final _imageKey = GlobalKey();

  Future<void> _pickImage() async {
    final XFile? pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      setState(() {
        _imageFile = File(pickedFile.path);
        _boundingBoxes.clear();
      });
    }
  }

  Future<void> _submitPrototype() async {
    if (_imageFile == null) return;

    // Read real pixel dimensions of the raw image file
    final bytes = await _imageFile!.readAsBytes();
    final ui.Image image = await decodeImageFromList(bytes);
    final double originalWidth = image.width.toDouble();
    final double originalHeight = image.height.toDouble();

    // Context dimensions of the displayed container area
    final RenderBox widgetBox = _imageKey.currentContext!.findRenderObject() as RenderBox;
    final Size widgetSize = widgetBox.size;

    final double imageAspect = originalWidth / originalHeight;
    final double widgetAspect = widgetSize.width / widgetSize.height;

    Size renderedSize;
    if (imageAspect > widgetAspect) {
      // image is letterboxed top/bottom
      renderedSize = Size(widgetSize.width, widgetSize.width / imageAspect);
    } else {
      // image is pillarboxed left/right
      renderedSize = Size(widgetSize.height * imageAspect, widgetSize.height);
    }

    final Offset imageOffset = Offset(
      (widgetSize.width - renderedSize.width) / 2,
      (widgetSize.height - renderedSize.height) / 2,
    );

    final double scaleX = originalWidth / renderedSize.width;
    final double scaleY = originalHeight / renderedSize.height;

    List<Map<String, dynamic>> normalizedBoxes = _boundingBoxes.map((box) {
      return {
        "label": box.label, // Transmit the correct user-assigned component label
        "x1": (box.start.dx - imageOffset.dx) * scaleX,
        "y1": (box.start.dy - imageOffset.dy) * scaleY,
        "x2": (box.end.dx - imageOffset.dx) * scaleX,
        "y2": (box.end.dy - imageOffset.dy) * scaleY,
      };
    }).toList();

    try {
      String uploadUrl = '${ApiService.baseUrl}/projects/${widget.project.id}/prototype';
      
      FormData formData = FormData.fromMap({
        "file": await MultipartFile.fromFile(_imageFile!.path, filename: "prototype.jpg"),
        "boxes": jsonEncode(normalizedBoxes), 
      });

      Dio dio = Dio();
      await dio.post(uploadUrl, data: formData);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prototype updated successfully'), backgroundColor: Colors.green),
      );
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Setup: ${widget.project.name}'),
        actions: [
          if (_imageFile != null)
            IconButton(icon: const Icon(Icons.cloud_upload), onPressed: _submitPrototype)
        ],
      ),
      body: _imageFile == null
          ? Center(
              child: ElevatedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.image),
                label: const Text('Select Prototype Photo'),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    onPanStart: (details) {
                      setState(() {
                        _currentBox = BoundingBoxRect(
                          start: details.localPosition, 
                          end: details.localPosition,
                          label: '',
                        );
                      });
                    },
                    onPanUpdate: (details) {
                      setState(() {
                        if (_currentBox != null) {
                          _currentBox!.end = details.localPosition;
                        }
                      });
                    },
                    onPanEnd: (details) async {
                      if (_currentBox != null) {
                        final tempBox = _currentBox!;
                        setState(() => _currentBox = null);

                        final TextEditingController labelController = TextEditingController();
                        
                        // Prompt user to enter label name for the specific bounded area
                        String? assignedLabel = await showDialog<String>(
                          context: context,
                          barrierDismissible: false,
                          builder: (context) => AlertDialog(
                            title: const Text('Label Component'),
                            content: TextField(
                              controller: labelController,
                              autofocus: true,
                              decoration: const InputDecoration(hintText: 'e.g., capacitor, IC, arduino'),
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
                          setState(() {
                            _boundingBoxes.add(BoundingBoxRect(
                              start: tempBox.start,
                              end: tempBox.end,
                              label: assignedLabel.trim(),
                            ));
                          });
                        }
                      }
                    },
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(_imageFile!, key: _imageKey, fit: BoxFit.contain),
                            CustomPaint(
                              painter: CanvasBBoxPainter(
                                boxes: _boundingBoxes,
                                activeBox: _currentBox,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () => setState(() => _boundingBoxes.clear()),
                        child: const Text('Clear Boxes'),
                      ),
                      ElevatedButton(onPressed: _pickImage, child: const Text('Change Image')),
                    ],
                  ),
                )
              ],
            ),
    );
  }
}

class CanvasBBoxPainter extends CustomPainter {
  final List<BoundingBoxRect> boxes;
  final BoundingBoxRect? activeBox;

  CanvasBBoxPainter({required this.boxes, this.activeBox});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (var box in boxes) {
      final rect = Rect.fromPoints(box.start, box.end);
      canvas.drawRect(rect, paint);

      // Render the label directly above the box canvas coordinates
      textPainter.text = TextSpan(
        text: box.label,
        style: const TextStyle(color: Colors.red, backgroundColor: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(rect.left, rect.top - 15));
    }

    if (activeBox != null) {
      final activePaint = Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(Rect.fromPoints(activeBox!.start, activeBox!.end), activePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CanvasBBoxPainter oldDelegate) => true;
}