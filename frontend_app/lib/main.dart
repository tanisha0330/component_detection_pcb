// lib/main.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/project.dart';
import 'services/api_service.dart';
import 'screens/project_hub_screen.dart';
import 'screens/login.dart';
import 'screens/admin_dashboard.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences prefs = await SharedPreferences.getInstance();
  bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
  String role = prefs.getString('role') ?? 'user';
  
  Widget initialScreen = const LoginScreen();
  if (isLoggedIn) {
    if (role == 'admin') {
      initialScreen = const AdminDashboardScreen();
    } else {
      initialScreen = const DashboardScreen();
    }
  }

  runApp(VisualPromptApp(initialScreen: initialScreen));
}

class VisualPromptApp extends StatelessWidget {
  final Widget initialScreen;
  const VisualPromptApp({super.key, required this.initialScreen});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Visual Prompt AI',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFE1D4C2),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6E473B),
          primary: const Color(0xFF291C0E),
          secondary: const Color(0xFF6E473B),
          surface: const Color(0xFFE1D4C2),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF291C0E),
          foregroundColor: Colors.white,
        ),
        useMaterial3: true,
      ),
      home: initialScreen,
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final ApiService _apiService = ApiService();
  late Future<List<Project>> _projectsFuture;
  String _selectedFilter = 'All';

  @override
  void initState() {
    super.initState();
    _refreshProjects();
  }

  void _refreshProjects() {
    setState(() {
      _projectsFuture = _apiService.getProjects();
    });
  }

  void _showCreateProjectDialog() {
    final TextEditingController nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create New Project'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(hintText: "Enter project name"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (nameController.text.isNotEmpty) {
                  await _apiService.createProject(nameController.text);
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  _refreshProjects();
                }
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  void _showLabelDialog(Project project) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Mark as ongoing'),
                onTap: () async {
                  Navigator.pop(context);
                  await _apiService.updateProjectLabel(project.id, 'ongoing');
                  _refreshProjects();
                },
              ),
              ListTile(
                leading: const Icon(Icons.check_circle),
                title: const Text('Mark as completed'),
                onTap: () async {
                  Navigator.pop(context);
                  await _apiService.updateProjectLabel(project.id, 'completed');
                  _refreshProjects();
                },
              ),
              ListTile(
                leading: const Icon(Icons.label),
                title: const Text('Mark custom...'),
                onTap: () {
                  Navigator.pop(context);
                  _showCustomLabelDialog(project);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showCustomLabelDialog(Project project) {
    final TextEditingController labelController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Set Custom Label'),
          content: TextField(
            controller: labelController,
            decoration: const InputDecoration(hintText: "Enter custom label"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (labelController.text.isNotEmpty) {
                  await _apiService.updateProjectLabel(project.id, labelController.text);
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  _refreshProjects();
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Projects'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () async {
              SharedPreferences prefs = await SharedPreferences.getInstance();
              await prefs.clear();
              if (!context.mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (context) => const LoginScreen()),
                (Route<dynamic> route) => false,
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<List<Project>>(
        future: _projectsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('No projects found. Create one!'));
          }

          final allProjects = snapshot.data!;
          final Set<String> labelSet = {'ongoing', 'completed'};
          for (var p in allProjects) {
            labelSet.add(p.label);
          }
          final List<String> availableFilters = ['All', ...labelSet];

          final displayedProjects = allProjects.where((p) {
            if (_selectedFilter == 'All') return true;
            return p.label == _selectedFilter;
          }).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: availableFilters.map((filter) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: FilterChip(
                        label: Text(filter),
                        selected: _selectedFilter == filter,
                        onSelected: (selected) {
                          setState(() {
                            _selectedFilter = filter;
                          });
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: displayedProjects.length,
                  itemBuilder: (context, index) {
                    final project = displayedProjects[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: ListTile(
                        title: Text(project.name),
                        subtitle: Text('Created: ${project.createdAt.substring(0, 10)}\nStatus: ${project.label}'),
                        trailing: const Icon(Icons.arrow_forward_ios),
                        onLongPress: () => _showLabelDialog(project),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ProjectHubScreen(project: project),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateProjectDialog,
        child: const Icon(Icons.add),
      ),
    );
  }
}
