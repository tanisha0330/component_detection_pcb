import 'dart:convert';
import 'package:flutter/foundation.dart';

class Detection {
  final String label;
  final double conf;
  final List<double> bbox; // [x1, y1, x2, y2]
  final String marking; // EasyOCR-read rating/value marking, e.g. "322"
  final String presence; // "present" | "missing" (DINOv2 similarity check)
  final double? similarity; // raw DINOv2 cosine similarity, if available

  Detection({
    required this.label,
    required this.conf,
    required this.bbox,
    this.marking = '',
    this.presence = 'present',
    this.similarity,
  });

  bool get isMissing => presence == 'missing';

  /// Label suffixed with its marking for display, e.g. "RESISTOR (322)".
  String get displayLabel => marking.isNotEmpty ? '$label ($marking)' : label;

  factory Detection.fromJson(Map<String, dynamic> json) {
    return Detection(
      label: json['label'],
      conf: (json['conf'] as num).toDouble(),
      bbox: (json['bbox'] as List).map((e) => (e as num).toDouble()).toList(),
      marking: (json['marking'] as String?) ?? '',
      presence: (json['presence'] as String?) ?? 'present',
      similarity: json['similarity'] == null
          ? null
          : (json['similarity'] as num).toDouble(),
    );
  }
}

class Sample {
  final int id;
  final int projectId;
  final String originalPath;
  final String? annotatedPath;
  final List<Detection> detections;
  final DateTime timestamp;

  Sample({
    required this.id,
    required this.projectId,
    required this.originalPath,
    this.annotatedPath,
    required this.detections,
    required this.timestamp,
  });

  factory Sample.fromJson(Map<String, dynamic> json) {
    List<Detection> parsedDetections = [];
    if (json['results_data'] != null) {
      try {
        final decoded = jsonDecode(json['results_data']);
        parsedDetections = (decoded as List).map((e) => Detection.fromJson(e)).toList();
      } catch (e) {
        debugPrint("Error parsing results_data: \${e}");
      }
    }

    return Sample(
      id: json['id'],
      projectId: json['project_id'],
      originalPath: json['original_path'],
      annotatedPath: json['annotated_path'],
      detections: parsedDetections,
      timestamp: DateTime.parse(json['timestamp']),
    );
  }
}
