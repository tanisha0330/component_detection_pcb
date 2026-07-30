// lib/services/api_service.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/project.dart';
import '../models/sample.dart';

class ApiService {
  // Use your computer's exact local network IP address
  static const String baseUrl = 'http://10.145.39.120:8000';

  final Dio _dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 120),
    receiveTimeout: const Duration(seconds: 120),
  ));

  Future<List<Project>> getProjects() async {
    try {
      final response = await _dio.get('/projects/');
      List<dynamic> data = response.data;
      return data.map((json) => Project.fromJson(json)).toList();
    } catch (e) {
      debugPrint("Error fetching projects: $e");
      throw Exception("Failed to load projects");
    }
  }

  Future<Project?> createProject(String name) async {
    try {
      final response = await _dio.post('/projects/', data: {'name': name});
      return Project.fromJson(response.data);
    } catch (e) {
      debugPrint("Error creating project: $e");
      return null;
    }
  }

  Future<Project?> getProject(int projectId) async {
    try {
      final response = await _dio.get('/projects/$projectId');
      return Project.fromJson(response.data);
    } catch (e) {
      debugPrint("Error fetching project: $e");
      return null;
    }
  }

  Future<bool> deleteProject(int projectId) async {
    try {
      final response = await _dio.delete('/projects/$projectId');
      return response.statusCode == 200;
    } catch (e) {
      debugPrint("Error deleting project: $e");
      return false;
    }
  }

  Future<bool> updateProjectLabel(int projectId, String label) async {
    try {
      final response = await _dio.put('/projects/$projectId/label', data: {'label': label});
      return response.statusCode == 200;
    } catch (e) {
      debugPrint("Error updating project label: $e");
      return false;
    }
  }


  /// Extracts a human-readable message from an error. FastAPI errors carry
  /// their real message in `response.data['detail']` — surfacing that
  /// instead of the raw DioException dump is what makes error SnackBars
  /// readable in the app.
  static String describeError(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['detail'] != null) {
        final detail = data['detail'];
        if (detail is String) return detail;
        return detail.toString();
      }
      if (e.message != null) return e.message!;
    }
    return e.toString();
  }

  // Add this inside lib/services/api_service.dart

  Future<Sample?> runInference(int projectId, File imageFile) async {
    try {
      String url = '/projects/$projectId/inference';
      FormData formData = FormData.fromMap({
        "file": await MultipartFile.fromFile(imageFile.path, filename: "sample_\${DateTime.now().millisecondsSinceEpoch}.jpg"),
      });

      // Create a temporary Dio instance with a LONG timeout for ML processing.
      // The pipeline now runs EasyOCR (CPU) + DINOv2 per matched component
      // on top of alignment/FastSAM, which can push a many-component board
      // past 2 minutes even after capping OCR crop size server-side.
      Dio inferenceDio = Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 300), // Wait up to 5 minutes for AI
      ));

      final response = await inferenceDio.post(url, data: formData);

      if (response.statusCode == 200) {
        return Sample.fromJson(response.data['sample']);
      }
      return null;
    } catch (e) {
      debugPrint("Error running inference: $e");
      throw Exception(describeError(e));
    }
  }

  Future<List<Sample>> getSamples(int projectId) async {
    try {
      final response = await _dio.get('/projects/$projectId/samples');
      List<dynamic> data = response.data;
      return data.map((json) => Sample.fromJson(json)).toList();
    } catch (e) {
      debugPrint("Error fetching samples: $e");
      return [];
    }
  }


  Future<bool> login({required String emailOrMobile, required String password, required bool isAdmin}) async {
    try {
      final response = await _dio.post('/api/login', data: {
        'email_or_mobile': emailOrMobile,
        'password': password,
        'role': isAdmin ? 'admin' : 'user',
      });
      return response.statusCode == 200 && response.data['status'] == 'success';
    } catch (e) {
      debugPrint("Login error: $e");
      return false;
    }
  }

  Future<bool> createUser({required String email, required String mobile, required String password}) async {
    try {
      final response = await _dio.post('/api/users', data: {
        'email': email,
        'mobile': mobile,
        'password': password,
      });
      return response.statusCode == 200 && response.data['status'] == 'success';
    } catch (e) {
      debugPrint("Create user error: $e");
      return false;
    }
  }
}