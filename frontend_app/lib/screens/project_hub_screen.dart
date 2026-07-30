// lib/screens/project_hub_screen.dart
import 'package:flutter/material.dart';
import '../models/project.dart';
import '../services/api_service.dart';
import 'inference_screen.dart';
import 'prototype_editor_screen.dart';

class ProjectHubScreen extends StatefulWidget {
  final Project project;

  const ProjectHubScreen({super.key, required this.project});

  @override
  State<ProjectHubScreen> createState() => _ProjectHubScreenState();
}

class _ProjectHubScreenState extends State<ProjectHubScreen> {
  final ApiService _apiService = ApiService();
  late Project _project;

  @override
  void initState() {
    super.initState();
    _project = widget.project;
  }

  /// Re-fetches the project from the server so prototype uploads made in the
  /// editor are reflected immediately, without needing an app restart.
  Future<void> _refreshProject() async {
    final updated = await _apiService.getProject(_project.id);
    if (updated != null && mounted) {
      setState(() => _project = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_project.name), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Project Workspace',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'ID: ${_project.id}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 48),

            // Card Button 1: Prototype Layout & Labeling Setup
            _buildHubCard(
              context: context,
              title: 'Setup Reference Layout',
              subtitle:
                  'Upload a reference prototype image and define component bounding boxes with labels.',
              icon: Icons.layers,
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        PrototypeEditorScreen(project: _project),
                  ),
                );
                await _refreshProject();
              },
            ),

            const SizedBox(height: 24),

            // Card Button 2: Run Live Component Detection Inference
            _buildHubCard(
              context: context,
              title: 'Run AI Inference Test',
              subtitle:
                  'Capture a test photo using the camera or gallery to predict and locate parts based on your reference model.',
              icon: Icons.memory,
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => InferenceScreen(project: _project),
                  ),
                );
                await _refreshProject();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHubCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 32,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
