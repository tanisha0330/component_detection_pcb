import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/project.dart';
import '../models/sample.dart';
import '../services/api_service.dart';
import 'sample_detail_screen.dart';

class InferenceScreen extends StatefulWidget {
  final Project project;
  const InferenceScreen({super.key, required this.project});

  @override
  State<InferenceScreen> createState() => _InferenceScreenState();
}

class _InferenceScreenState extends State<InferenceScreen> {
  bool _isProcessing = false;
  late Future<List<Sample>> _samplesFuture;
  
  final ImagePicker _picker = ImagePicker();
  final ApiService _apiService = ApiService();

  final Color darkBrown = const Color(0xFF291C0E);
  final Color greenAccent = const Color(0xFF6E473B);

  @override
  void initState() {
    super.initState();
    _refreshSamples();
  }

  void _refreshSamples() {
    setState(() {
      _samplesFuture = _apiService.getSamples(widget.project.id);
    });
  }

  Future<void> _captureAndRunAI() async {
    final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
    if (photo == null) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      Sample? newSample = await _apiService.runInference(widget.project.id, File(photo.path));
      
      setState(() {
        _isProcessing = false;
      });

      if (newSample != null) {
        _refreshSamples();
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => SampleDetailScreen(sample: newSample)),
        );
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI Processing failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Inference History: ${widget.project.name}'),
      ),
      body: _isProcessing
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text("AI is analyzing the image...\nThis may take a few seconds.", textAlign: TextAlign.center),
                ],
              ),
            )
          : FutureBuilder<List<Sample>>(
              future: _samplesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                } else if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return const Center(child: Text('No inferences run yet. Tap the camera to start!'));
                }

                final samples = snapshot.data!;
                return ListView.builder(
                  itemCount: samples.length,
                  itemBuilder: (context, index) {
                    final sample = samples[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: ListTile(
                        leading: const Icon(Icons.image),
                        title: Text('Run #${sample.id}'),
                        subtitle: Text('Detections: ${sample.detections.length}\nTime: ${sample.timestamp.toLocal().toString().substring(0, 16)}'),
                        trailing: const Icon(Icons.arrow_forward_ios),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => SampleDetailScreen(sample: sample)),
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
}
