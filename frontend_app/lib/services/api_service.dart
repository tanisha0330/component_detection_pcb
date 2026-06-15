// lib/services/api_service.dart
import 'dart:io';
import 'package:dio/dio.dart';
import '../models/project.dart';


class ApiService {
  // Use your computer's exact local network IP address
  static const String baseUrl = 'http://10.145.23.44:8000';

  final Dio _dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 3),
  ));

  Future<List<Project>> getProjects() async {
    try {
      final response = await _dio.get('/projects/');
      List<dynamic> data = response.data;
      return data.map((json) => Project.fromJson(json)).toList();
    } catch (e) {
      print("Error fetching projects: $e");
      throw Exception("Failed to load projects");
    }
  }

  Future<Project?> createProject(String name) async {
    try {
      final response = await _dio.post('/projects/', data: {'name': name});
      return Project.fromJson(response.data);
    } catch (e) {
      print("Error creating project: $e");
      return null;
    }
  }


  // Add this inside lib/services/api_service.dart

  Future<String?> runInference(int projectId, File imageFile) async {
    try {
      String url = '/projects/$projectId/inference';
      FormData formData = FormData.fromMap({
        "file": await MultipartFile.fromFile(imageFile.path, filename: "sample.jpg"),
      });

      // Create a temporary Dio instance with a LONG timeout for ML processing
      Dio inferenceDio = Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 120), // Wait up to 2 minutes for AI
      ));

      final response = await inferenceDio.post(url, data: formData);

      if (response.statusCode == 200) {
        // The backend returns a relative URL like "/storage/samples/result_..."
        // We append it to the base URL so Flutter can load the image over the network
        String relativeUrl = response.data['annotated_output_url'];
        return '$baseUrl$relativeUrl';
      }
      return null;
    } catch (e) {
      print("Error running inference: $e");
      throw Exception("Inference failed: $e");
    }
  }


  
}