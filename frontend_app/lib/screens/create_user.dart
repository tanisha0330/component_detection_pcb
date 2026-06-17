import 'package:flutter/material.dart';
import '../services/api_service.dart';

class CreateUserScreen extends StatefulWidget {
  const CreateUserScreen({super.key});

  @override
  State<CreateUserScreen> createState() => _CreateUserScreenState();
}

class _CreateUserScreenState extends State<CreateUserScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final ApiService _apiService = ApiService();

  final Color darkBrown = const Color(0xFF291C0E);
  final Color greenAccent = const Color(0xFF6E473B);
  final Color grayishBrown = const Color(0xFFBEB5A9);
  final Color lightCream = const Color(0xFFE1D4C2);
  
  bool _isLoading = false;

  Future<void> _createUser() async {
    final email = _emailController.text.trim();
    final mobile = _mobileController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || mobile.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields')),
      );
      return;
    }

    setState(() => _isLoading = true);

    bool success = await _apiService.createUser(
      email: email,
      mobile: mobile,
      password: password,
    );

    setState(() => _isLoading = false);

    if (success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User created successfully!')),
        );
        Navigator.pop(context); // Return to Admin Dashboard
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to create user. Please check if email already exists.')),
        );
      }
    }
  }

  InputDecoration _buildInputDecoration(String hintText) {
    return InputDecoration(
      filled: true,
      fillColor: lightCream,
      hintText: hintText,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create New User'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              
              Text(
                "User Details",
                style: TextStyle(
                  color: darkBrown,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 30),

              // Email Field
              Text("Gmail", style: TextStyle(color: darkBrown, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                style: TextStyle(color: darkBrown),
                keyboardType: TextInputType.emailAddress,
                decoration: _buildInputDecoration("user@example.com"),
              ),
              const SizedBox(height: 20),

              // Mobile Field
              Text("Mobile Number", style: TextStyle(color: darkBrown, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _mobileController,
                style: TextStyle(color: darkBrown),
                keyboardType: TextInputType.phone,
                decoration: _buildInputDecoration("+1 234 567 8900"),
              ),
              const SizedBox(height: 20),

              // Password Field
              Text("Password", style: TextStyle(color: darkBrown, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                style: TextStyle(color: darkBrown),
                obscureText: true,
                decoration: _buildInputDecoration("••••••••••"),
              ),
              const SizedBox(height: 40),

              // CTA Button
              ElevatedButton(
                onPressed: _isLoading ? null : _createUser,
                style: ElevatedButton.styleFrom(
                  backgroundColor: greenAccent,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading 
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text(
                      "Save User",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
