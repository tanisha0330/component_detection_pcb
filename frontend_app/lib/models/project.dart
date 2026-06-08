// lib/models/project.dart

class Project {
  final int id;
  final String name;
  final String createdAt;
  final String? prototypePath;

  Project({
    required this.id,
    required this.name,
    required this.createdAt,
    this.prototypePath,
  });

  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: json['id'],
      name: json['name'],
      createdAt: json['created_at'],
      prototypePath: json['prototype_path'],
    );
  }
}