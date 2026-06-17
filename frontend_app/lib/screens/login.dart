import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../main.dart'; // To get DashboardScreen
import 'admin_dashboard.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool isAdmin = false;
  bool isLoading = false;

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final ApiService _apiService = ApiService();

  final Color darkBrown = const Color(0xFF291C0E);
  final Color greenAccent = const Color(0xFF6E473B); // Dark brown accent based on prompt
  final Color mediumTan = const Color(0xFFA78D78);
  final Color grayishBrown = const Color(0xFFBEB5A9);
  final Color lightCream = const Color(0xFFE1D4C2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightCream,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              // Header
              Text(
                "User Login",
                style: TextStyle(
                  color: darkBrown,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Assigned inspector",
                style: TextStyle(
                  color: mediumTan,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 40),
              
              // Avatar
              Center(
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: greenAccent,
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Text(
                      "U",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),

              // Role Toggle
              Container(
                height: 50,
                decoration: BoxDecoration(
                  color: grayishBrown.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(25),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            isAdmin = true;
                          });
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isAdmin ? greenAccent : Colors.transparent,
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: Center(
                            child: Text(
                              "Admin",
                              style: TextStyle(
                                color: isAdmin ? Colors.white : darkBrown,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            isAdmin = false;
                          });
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: !isAdmin ? greenAccent : Colors.transparent,
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: Center(
                            child: Text(
                              "User",
                              style: TextStyle(
                                color: !isAdmin ? Colors.white : darkBrown,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),

              // Email Field
              Text(
                "Email / mobile",
                style: TextStyle(
                  color: mediumTan,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _usernameController,
                style: TextStyle(color: darkBrown),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: lightCream,
                  hintText: "operator@plant.com",
                  hintStyle: TextStyle(color: darkBrown.withValues(alpha: 0.5)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: grayishBrown),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: darkBrown, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Password Field
              Text(
                "Password",
                style: TextStyle(
                  color: mediumTan,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: true,
                style: TextStyle(color: darkBrown),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: lightCream,
                  hintText: "••••••••••",
                  hintStyle: TextStyle(color: darkBrown.withValues(alpha: 0.5)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: grayishBrown),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: darkBrown, width: 2),
                  ),
                ),
              ),
              
              const Spacer(),
              
              // CTA Button
              ElevatedButton(
                onPressed: isLoading ? null : () async {
                  setState(() {
                    isLoading = true;
                  });
                  bool success = await _apiService.login(
                    emailOrMobile: _usernameController.text.trim(),
                    password: _passwordController.text,
                    isAdmin: isAdmin,
                  );
                  setState(() {
                    isLoading = false;
                  });
                  if (success) {
                    SharedPreferences prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('isLoggedIn', true);
                    await prefs.setString('role', isAdmin ? 'admin' : 'user');
                    
                    if (!context.mounted) return;

                    if (isAdmin) {
                      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AdminDashboardScreen()));
                    } else {
                      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const DashboardScreen()));
                    }
                  } else {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid credentials')));
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: greenAccent,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: isLoading 
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(
                      isAdmin ? "Open dashboard" : "Login",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
