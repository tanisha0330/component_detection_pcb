import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/project.dart';
import '../models/sample.dart';
import '../services/api_service.dart';
import 'sample_detail_screen.dart';
import 'prototype_editor_screen.dart';

class InferenceScreen extends StatefulWidget {
  final Project project;
  const InferenceScreen({super.key, required this.project});

  @override
  State<InferenceScreen> createState() => _InferenceScreenState();
}

class _InferenceScreenState extends State<InferenceScreen> {
  bool _isProcessing = false;
  late Future<List<Sample>> _samplesFuture;
  late Project _project;

  final ImagePicker _picker = ImagePicker();
  final ApiService _apiService = ApiService();

  final Color darkBrown = const Color(0xFF291C0E);
  final Color greenAccent = const Color(0xFF6E473B);

  @override
  void initState() {
    super.initState();
    _project = widget.project;
    _refreshSamples();
  }

  void _refreshSamples() {
    setState(() {
      _samplesFuture = _apiService.getSamples(_project.id);
    });
  }

  /// Re-fetches the project so a prototype uploaded from this screen is
  /// reflected immediately, without needing an app restart.
  Future<void> _refreshProject() async {
    final updated = await _apiService.getProject(_project.id);
    if (updated != null && mounted) {
      setState(() => _project = updated);
    }
  }

  /// Returns true if a prototype has been uploaded for this project.
  bool get _hasPrototype =>
      _project.prototypePath != null && _project.prototypePath!.isNotEmpty;

  /// Shows a bottom sheet letting the user pick Camera or Gallery as the
  /// image source. Returns null if the user dismisses without choosing.
  Future<ImageSource?> _pickImageSource() {
    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take Photo'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from Gallery'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Shows a dialog prompting the user to upload a prototype first.
  Future<void> _showNoPrototypeDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
          title: const Text(
            'No Prototype Uploaded',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: const Text(
            'This project doesn\'t have a reference prototype yet.\n\n'
            'Please upload a prototype image and define component bounding boxes '
            'before running AI inference.',
            textAlign: TextAlign.center,
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Upload Prototype'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6E473B),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                Navigator.of(ctx).pop(); // close dialog
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        PrototypeEditorScreen(project: _project),
                  ),
                ).then((_) async {
                  // Refresh the project (prototype may now exist) and samples
                  await _refreshProject();
                  _refreshSamples();
                });
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _captureAndRunAI() async {
    // Guard: prototype must be uploaded before running inference
    if (!_hasPrototype) {
      await _showNoPrototypeDialog();
      return;
    }

    final ImageSource? source = await _pickImageSource();
    if (source == null) return;

    final XFile? photo = await _picker.pickImage(source: source);
    if (photo == null) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      Sample? newSample =
          await _apiService.runInference(_project.id, File(photo.path));

      setState(() {
        _isProcessing = false;
      });

      if (newSample != null) {
        _refreshSamples();
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (context) => SampleDetailScreen(sample: newSample)),
        );
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
      });
      if (!mounted) return;

      // If there's an error AND no prototype, surface the prototype dialog
      if (!_hasPrototype) {
        await _showNoPrototypeDialog();
      } else {
        String msg = e.toString();
        if (msg.startsWith('Exception: ')) {
          msg = msg.substring('Exception: '.length);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(msg),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 6)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Inference History: ${_project.name}'),
      ),
      body: _isProcessing
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text(
                    "AI is analyzing the image...\nThis may take a few seconds.",
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          : FutureBuilder<List<Sample>>(
              future: _samplesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                // ── Error state ──────────────────────────────────────────────
                if (snapshot.hasError) {
                  if (!_hasPrototype) {
                    return _buildNoPrototypePlaceholder(context);
                  }
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline,
                              size: 64, color: Colors.red),
                          const SizedBox(height: 16),
                          Text(
                            'Failed to load inference history.',
                            style: Theme.of(context).textTheme.titleMedium,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${snapshot.error}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _refreshSamples,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                // ── Empty state ──────────────────────────────────────────────
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  if (!_hasPrototype) {
                    return _buildNoPrototypePlaceholder(context);
                  }
                  return const Center(
                    child: Text(
                        'No inferences run yet. Tap the camera to start!'),
                  );
                }

                // ── Results list ─────────────────────────────────────────────
                final samples = snapshot.data!;
                return ListView.builder(
                  itemCount: samples.length,
                  itemBuilder: (context, index) {
                    final sample = samples[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: ListTile(
                        leading: const Icon(Icons.image),
                        title: Text('Run #${sample.id}'),
                        subtitle: Text(
                            'Detections: ${sample.detections.length}\nTime: ${sample.timestamp.toLocal().toString().substring(0, 16)}'),
                        trailing: const Icon(Icons.arrow_forward_ios),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) =>
                                    SampleDetailScreen(sample: sample)),
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
      floatingActionButton: _isProcessing
          ? null
          : FloatingActionButton.extended(
              onPressed: _captureAndRunAI,
              backgroundColor: greenAccent,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Run New Inference'),
            ),
    );
  }

  /// Inline placeholder shown when no prototype has been uploaded yet.
  Widget _buildNoPrototypePlaceholder(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.upload_file,
                  size: 64, color: Colors.orange.shade700),
            ),
            const SizedBox(height: 24),
            Text(
              'Prototype Required',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            Text(
              'You haven\'t uploaded a reference prototype for this project yet. '
              'A prototype is needed for the AI to run component detection.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, height: 1.5),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Upload Prototype Now'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6E473B),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        PrototypeEditorScreen(project: _project),
                  ),
                ).then((_) async {
                  await _refreshProject();
                  _refreshSamples();
                });
              },
            ),
          ],
        ),
      ),
    );
  }
}
