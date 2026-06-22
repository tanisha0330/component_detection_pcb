import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../main.dart';
import 'admin_dashboard.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  bool isAdmin = false;
  bool isLoading = false;

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final ApiService _apiService = ApiService();

  final FocusNode _emailFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  late AnimationController _animController;
  late Animation<double> _fadeIn;
  late Animation<Offset> _slideUp;

  final Color darkBrown = const Color(0xFF291C0E);
  final Color brownAccent = const Color(0xFF6E473B);
  final Color mediumTan = const Color(0xFFA78D78);
  final Color grayishBrown = const Color(0xFFBEB5A9);
  final Color lightCream = const Color(0xFFE1D4C2);

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeIn = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _slideUp = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));

    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
    final isKeyboardOpen = bottomPadding > 0;

    return Scaffold(
      backgroundColor: lightCream,
      // resizeToAvoidBottomInset: true is the default — keeps it true
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeIn,
          child: SlideTransition(
            position: _slideUp,
            child: SingleChildScrollView(
              // Scroll content up when keyboard appears
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                bottom: bottomPadding > 0 ? 24 : 32,
              ),
              child: ConstrainedBox(
                // Ensure content fills at least the visible height
                constraints: BoxConstraints(
                  minHeight: MediaQuery.of(context).size.height -
                      MediaQuery.of(context).padding.top -
                      MediaQuery.of(context).padding.bottom -
                      bottomPadding,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 40),

                      // Header — hide when keyboard is fully open to save space
                      AnimatedOpacity(
                        opacity: isKeyboardOpen ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 200),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          height: isKeyboardOpen ? 0 : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
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
                            ],
                          ),
                        ),
                      ),

                      // Avatar — shrinks when keyboard appears
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                        height: isKeyboardOpen ? 16 : 40,
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                        height: isKeyboardOpen ? 0 : 100,
                        child: isKeyboardOpen
                            ? const SizedBox.shrink()
                            : Center(
                                child: Container(
                                  width: 100,
                                  height: 100,
                                  decoration: BoxDecoration(
                                    color: brownAccent,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: brownAccent.withValues(alpha: 0.35),
                                        blurRadius: 16,
                                        offset: const Offset(0, 6),
                                      ),
                                    ],
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
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        height: isKeyboardOpen ? 24 : 40,
                      ),

                      // Role Toggle with animated pill
                      _RoleToggle(
                        isAdmin: isAdmin,
                        onChanged: (val) => setState(() => isAdmin = val),
                        brownAccent: brownAccent,
                        darkBrown: darkBrown,
                        grayishBrown: grayishBrown,
                      ),

                      const SizedBox(height: 32),

                      // Email Field
                      _FieldLabel(label: "Email / mobile", color: mediumTan),
                      const SizedBox(height: 8),
                      _AnimatedTextField(
                        controller: _usernameController,
                        focusNode: _emailFocus,
                        hint: "operator@plant.com",
                        obscure: false,
                        darkBrown: darkBrown,
                        grayishBrown: grayishBrown,
                        lightCream: lightCream,
                        brownAccent: brownAccent,
                        onSubmitted: (_) =>
                            FocusScope.of(context).requestFocus(_passwordFocus),
                        textInputAction: TextInputAction.next,
                      ),

                      const SizedBox(height: 24),

                      // Password Field
                      _FieldLabel(label: "Password", color: mediumTan),
                      const SizedBox(height: 8),
                      _AnimatedTextField(
                        controller: _passwordController,
                        focusNode: _passwordFocus,
                        hint: "••••••••••",
                        obscure: true,
                        darkBrown: darkBrown,
                        grayishBrown: grayishBrown,
                        lightCream: lightCream,
                        brownAccent: brownAccent,
                        textInputAction: TextInputAction.done,
                      ),

                      const Spacer(),
                      const SizedBox(height: 32),

                      // CTA Button
                      _LoginButton(
                        isLoading: isLoading,
                        isAdmin: isAdmin,
                        brownAccent: brownAccent,
                        onTap: () async {
                          FocusScope.of(context).unfocus();
                          setState(() => isLoading = true);
                          bool success = await _apiService.login(
                            emailOrMobile: _usernameController.text.trim(),
                            password: _passwordController.text,
                            isAdmin: isAdmin,
                          );
                          setState(() => isLoading = false);
                          if (success) {
                            SharedPreferences prefs =
                                await SharedPreferences.getInstance();
                            await prefs.setBool('isLoggedIn', true);
                            await prefs.setString(
                                'role', isAdmin ? 'admin' : 'user');
                            if (!context.mounted) return;
                            if (isAdmin) {
                              Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminDashboardScreen()));
                            } else {
                              Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const DashboardScreen()));
                            }
                          } else {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('Invalid credentials'),
                                backgroundColor: const Color(0xFF6E473B),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Role Toggle ──────────────────────────────────────────────────────────────

class _RoleToggle extends StatelessWidget {
  final bool isAdmin;
  final ValueChanged<bool> onChanged;
  final Color brownAccent, darkBrown, grayishBrown;

  const _RoleToggle({
    required this.isAdmin,
    required this.onChanged,
    required this.brownAccent,
    required this.darkBrown,
    required this.grayishBrown,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: grayishBrown.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(25),
      ),
      child: Stack(
        children: [
          // Animated sliding pill
          AnimatedAlign(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: isAdmin ? Alignment.centerLeft : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: brownAccent,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: brownAccent.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ],
                ),
              ),
            ),
          ),
          // Labels
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(true),
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                        color: isAdmin ? Colors.white : darkBrown,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      child: const Text("Admin"),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(false),
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                        color: !isAdmin ? Colors.white : darkBrown,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      child: const Text("User"),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Field Label ───────────────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String label;
  final Color color;
  const _FieldLabel({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600),
    );
  }
}

// ── Animated TextField ────────────────────────────────────────────────────────

class _AnimatedTextField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final bool obscure;
  final Color darkBrown, grayishBrown, lightCream, brownAccent;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  const _AnimatedTextField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.obscure,
    required this.darkBrown,
    required this.grayishBrown,
    required this.lightCream,
    required this.brownAccent,
    required this.textInputAction,
    this.onSubmitted,
  });

  @override
  State<_AnimatedTextField> createState() => _AnimatedTextFieldState();
}

class _AnimatedTextFieldState extends State<_AnimatedTextField> {
  bool _hasFocus = false;
  bool _showPassword = false; // only relevant when obscure=true

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(() {
      setState(() => _hasFocus = widget.focusNode.hasFocus);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: widget.lightCream,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _hasFocus ? widget.brownAccent : widget.grayishBrown,
          width: _hasFocus ? 2 : 1,
        ),
        boxShadow: _hasFocus
            ? [
                BoxShadow(
                  color: widget.brownAccent.withValues(alpha: 0.15),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ]
            : [],
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        obscureText: widget.obscure && !_showPassword,
        style: TextStyle(color: widget.darkBrown),
        textInputAction: widget.textInputAction,
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          filled: false,
          hintText: widget.hint,
          hintStyle:
              TextStyle(color: widget.darkBrown.withValues(alpha: 0.4)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: InputBorder.none,
          // Toggle visibility icon for password fields
          suffixIcon: widget.obscure
              ? IconButton(
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                    color: widget.grayishBrown,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                )
              : null,
        ),
      ),
    );
  }
}

// ── Login Button ──────────────────────────────────────────────────────────────

class _LoginButton extends StatefulWidget {
  final bool isLoading, isAdmin;
  final Color brownAccent;
  final VoidCallback onTap;

  const _LoginButton({
    required this.isLoading,
    required this.isAdmin,
    required this.brownAccent,
    required this.onTap,
  });

  @override
  State<_LoginButton> createState() => _LoginButtonState();
}

class _LoginButtonState extends State<_LoginButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        if (!widget.isLoading) widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 54,
          decoration: BoxDecoration(
            color: widget.isLoading
                ? widget.brownAccent.withValues(alpha: 0.7)
                : widget.brownAccent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: _pressed
                ? []
                : [
                    BoxShadow(
                      color: widget.brownAccent.withValues(alpha: 0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    )
                  ],
          ),
          child: Center(
            child: widget.isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5),
                  )
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      widget.isAdmin ? "Open dashboard" : "Login",
                      key: ValueKey(widget.isAdmin),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}