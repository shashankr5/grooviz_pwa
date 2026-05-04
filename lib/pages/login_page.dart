import 'dart:async';

import 'package:flutter/material.dart';
import 'main_navigation.dart';
import '../services/login_service.dart';
import '../services/fcm_service.dart';
import '../utils/user_session_helper.dart';
import '../services/profile_service.dart';
import '../utils/app_colors.dart';
import 'forgot_password_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();

  bool _obscurePassword = true;
  bool _isFormValid = false;
  bool _isLoading = false;

  // Tracks whether FCMService is still acquiring a token.
  // When true, the login button shows "Preparing secure connection..."
  // instead of the spinner, so the user understands the delay.
  FCMStatus _fcmStatus = FCMService.currentStatus;
  StreamSubscription<FCMStatus>? _fcmStatusSub;

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fcmStatus = FCMService.currentStatus;
    _fcmStatusSub = FCMService.statusStream.listen((status) {
      if (mounted) setState(() => _fcmStatus = status);
    });
  }

  @override
  void dispose() {
    _fcmStatusSub?.cancel();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _validateForm() {
    setState(() => _isFormValid = _formKey.currentState?.validate() ?? false);
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final loginService = LoginService();
    final response = await loginService.login(
      username: _usernameController.text.trim(),
      password: _passwordController.text.trim(),
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    // ── Login failed ──────────────────────────────────────────────────────
    if (!response['success']) {
      final isFcmPending = response['fcm_pending'] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(response['message'] ?? 'Login failed'),
          backgroundColor: AppColors.error,
          // Give extra time for the FCM hint so user can read it fully.
          duration: Duration(seconds: isFcmPending ? 5 : 3),
          action: isFcmPending
              ? SnackBarAction(
                  label: 'Retry',
                  textColor: Colors.white,
                  onPressed: _login,
                )
              : null,
        ),
      );
      return;
    }

    // ── Login succeeded ───────────────────────────────────────────────────
    await UserSessionHelper.saveUserId(response['user_id']);
    await UserSessionHelper.saveIsLoggedIn(true);

    final profileRes = await ProfileService().getProfile();

    if (!mounted) return;

    if (!profileRes['success']) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Profile loading failed: ${profileRes["message"]}'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    // Wipes the entire navigation stack — nothing to go back to
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const MainNavigation()),
      (route) => false,
    );
  }

  // Returns a short status line shown below the login button.
  // Visible only while FCM is acquiring — disappears once ready.
  Widget _buildFcmStatusHint() {
    if (_fcmStatus != FCMStatus.acquiring) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppColors.primary.withOpacity(0.6),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Preparing secure connection...',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Disable the button while loading OR while FCM is still acquiring
    // on a first launch / reinstall. On subsequent launches _fcmStatus
    // is already FCMStatus.ready before the user sees this screen.
    final bool buttonEnabled =
        _isFormValid && !_isLoading && _fcmStatus != FCMStatus.acquiring;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Form(
            key: _formKey,
            onChanged: _validateForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 60),

                // Logo
                Center(
                  child: Container(
                    height: 100,
                    width: 100,
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person,
                      size: 50,
                      color: AppColors.primary,
                    ),
                  ),
                ),

                const SizedBox(height: 25),

                const Center(
                  child: Text(
                    'Welcome',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(height: 6),

                Center(
                  child: Text(
                    'Login to continue',
                    style: TextStyle(fontSize: 15, color: Colors.grey),
                  ),
                ),

                const SizedBox(height: 40),

                const Text(
                  'Username',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
                const SizedBox(height: 8),

                TextFormField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    hintText: 'Enter username',
                    prefixIcon: const Icon(Icons.person_outline),
                    filled: true,
                    fillColor: AppColors.bgLight,
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 16, horizontal: 12),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(
                          color: AppColors.primary, width: 1.5),
                    ),
                  ),
                  validator: (v) => v!.isEmpty ? 'Username required' : null,
                ),

                const SizedBox(height: 20),

                const Text(
                  'Password',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
                const SizedBox(height: 8),

                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    hintText: 'Enter password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                    filled: true,
                    fillColor: AppColors.bgLight,
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 16, horizontal: 12),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(
                          color: AppColors.primary, width: 1.5),
                    ),
                  ),
                  validator: (v) => v!.isEmpty ? 'Password required' : null,
                ),

                const SizedBox(height: 12),

                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ForgotPasswordPage()),
                      ),
                      child: const Text(
                        'Forgot Password?',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    onPressed: buttonEnabled ? _login : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      disabledBackgroundColor: Colors.grey.shade400,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isLoading
                        ? const CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          )
                        : const Text(
                            'Login',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),

                // ── FCM status hint ──────────────────────────────────────
                // Appears automatically during GPS recovery on first launch
                // or after reinstall. Invisible on all subsequent logins.
                _buildFcmStatusHint(),

                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}