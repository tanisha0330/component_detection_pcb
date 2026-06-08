// lib/screens/inference_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/project.dart';
import '../services/api_service.dart';

class InferenceScreen extends StatefulWidget {
  final Project project;
  const InferenceScreen({super.key, required this.project});

  @override
  State<InferenceScreen> createState() => _InferenceScreenState();
}

class _InferenceScreenState extends State<InferenceScreen> {
  File? _selectedImage;
  String? _annotatedImageUrl;
  bool _isProcessing = false;
  
  final ImagePicker _picker = ImagePicker();
  final ApiService _apiService = ApiService();

  // Method to open the camera
  Future<void> _captureImage() async {
    final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
    // If you prefer gallery testing, change to: ImageSource.gallery

    if (photo != null) {
      setState(() {
        _selectedImage = File(photo.path);
        _annotatedImageUrl = null; // Clear previous results
      });
    }
  }

  // Method to send to FastAPI
  Future<void> _runAI() async {
    if (_selectedImage == null) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      String? resultUrl = await _apiService.runInference(widget.project.id, _selectedImage!);
      
      setState(() {
        _annotatedImageUrl = resultUrl;
        _isProcessing = false;
      });
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
        title: Text('Test AI: ${widget.project.name}'),
        actions: [
          if (_annotatedImageUrl != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() {
                _selectedImage = null;
                _annotatedImageUrl = null;
              }),
            )
        ],
      ),
      body: Center(
        child: _buildBodyContent(),
      ),
      floatingActionButton: (_isProcessing || _annotatedImageUrl != null) 
          ? null 
          : FloatingActionButton.extended(
              onPressed: _captureImage,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Capture Sample'),
            ),
    );
  }

  Widget _buildBodyContent() {
    // State 1: Processing ML Model
    if (_isProcessing) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 20),
          Text(
            "AI is analyzing the image...\nThis may take a few seconds.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
        ],
      );
    }

    // State 2: Display Annotated Result
    if (_annotatedImageUrl != null) {
      return Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text("Detection Results", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: InteractiveViewer(
              panEnabled: true,
              boundaryMargin: const EdgeInsets.all(20),
              minScale: 1,
              maxScale: 4,
              // Fetch image over HTTP from your FastAPI static storage
              child: Image.network(
                _annotatedImageUrl!,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return const Center(child: CircularProgressIndicator());
                },
                errorBuilder: (context, error, stackTrace) => 
                  const Center(child: Text("Failed to load result image.", style: TextStyle(color: Colors.red))),
              ),
            ),
          ),
        ],
      );
    }

    // State 3: Image Selected, ready to upload
    if (_selectedImage != null) {
      return Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Image.file(_selectedImage!, fit: BoxFit.contain),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20.0),
            child: ElevatedButton.icon(
              onPressed: _runAI,
              icon: const Icon(Icons.memory),
              label: const Text("Run Inference"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
          )
        ],
      );
    }

    // State 4: Default Empty State
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.camera, size: 80, color: Colors.grey),
        SizedBox(height: 16),
        Text("No sample selected.\nTap the camera to capture a test image.", textAlign: TextAlign.center),
      ],
    );
  }
}