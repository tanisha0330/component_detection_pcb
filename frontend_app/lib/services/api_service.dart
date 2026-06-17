// lib/services/api_service.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/project.dart';
import '../models/sample.dart';

class ApiService {
  // Use your computer's exact local network IP address
  static const String baseUrl = 'http://10.145.47.188:8000';

  final Dio _dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
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

  Future<bool> updateProjectLabel(int projectId, String label) async {
    try {
      final response = await _dio.put('/projects/$projectId/label', data: {'label': label});
      return response.statusCode == 200;
    } catch (e) {
      debugPrint("Error updating project label: $e");
      return false;
    }
  }


  // Add this inside lib/services/api_service.dart

  Future<Sample?> runInference(int projectId, File imageFile) async {
    try {
      String url = '/projects/$projectId/inference';
      FormData formData = FormData.fromMap({
        "file": await MultipartFile.fromFile(imageFile.path, filename: "sample_\${DateTime.now().millisecondsSinceEpoch}.jpg"),
      });

      // Create a temporary Dio instance with a LONG timeout for ML processing
      Dio inferenceDio = Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 120), // Wait up to 2 minutes for AI
      ));

      final response = await inferenceDio.post(url, data: formData);

      if (response.statusCode == 200) {
        return Sample.fromJson(response.data['sample']);
      }
      return null;
    } catch (e) {
      debugPrint("Error running inference: $e");
      throw Exception("Inference failed: $e");
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