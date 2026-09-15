import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'main_navigation.dart';
import '../components/app_button.dart';
import '../services/login_service.dart';
import '../utils/user_session_helper.dart';
import '../services/profile_service.dart';
import '../services/websocket_service.dart';
import '../services/home_service.dart'; // Added for escalation permissions
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../utils/validators.dart';
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

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _validateForm() {
    setState(() => _isFormValid = _formKey.currentState?.validate() ?? false);
  }

  // ── Fetch and store escalation permissions ──────────────────────────────
  Future<void> _fetchAndStoreEscalationPermissions() async {
    try {
      final result = await HomeService().getUserDeptDetails();
      if (result['success'] == true) {
        final departments = result['departments'] as List? ?? [];
        if (departments.isNotEmpty) {
          bool mergedAccept = false, mergedReassign = false, mergedDecline = false;
          final Map<String, Map<String, bool>> deptMap = {};

          for (final dept in departments) {
            final deptId = dept['department_id'];
            if (deptId == null) continue;
            final key = deptId.toString();

            // json_data may arrive as a decoded Map or a raw JSON string
            dynamic raw = dept['json_data'];
            Map jsonData = {};
            if (raw is Map) {
              jsonData = raw;
            } else if (raw is String && raw.isNotEmpty) {
              try { jsonData = jsonDecode(raw) as Map? ?? {}; } catch (_) {}
            }

            final accept   = jsonData['is_accept']  == 'Y';
            final reassign = jsonData['reassign']    == 'Y';
            final decline  = jsonData['is_decline']  == 'Y';

            deptMap[key] = {
              'isAccept':  accept,
              'reassign':  reassign,
              'isDecline': decline,
            };

            // OR-merge for the flat fallback still read by tasks_page
            if (accept)   mergedAccept   = true;
            if (reassign) mergedReassign = true;
            if (decline)  mergedDecline  = true;
          }

          // Per-dept map — used by ticket_details_page for accurate per-ticket buttons
          await UserSessionHelper.saveDeptPermissionsMap(deptMap);

          // Flat bools — fallback for tasks_page and any null-dept tickets
          await UserSessionHelper.saveEscalationPermissions(
            isAccept:  mergedAccept,
            reassign:  mergedReassign,
            isDecline: mergedDecline,
          );
          print('Escalation permissions saved successfully.');
        }
      } else {
        print('Failed to fetch escalation permissions: ${result['message']}');
      }
    } catch (e) {
      print('Error fetching escalation permissions: $e');
    }
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(response['message'] ?? 'Login failed'),
          backgroundColor: AppColors.error,
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

    final role = await UserSessionHelper.getRole();
    final depts = await UserSessionHelper.getDepartments();
    if (role != null) await UserSessionHelper.saveInitialRole(role);
    if (depts.isNotEmpty) await UserSessionHelper.saveInitialDepartments(depts);

    // ── Fetch and store escalation permissions (non‑blocking) ────────────
    // We call this in the background so the user doesn't wait.
    _fetchAndStoreEscalationPermissions();

    // FIX-9 (Bug 9): WebSocketService().connect() was never called anywhere
    final enterpriseId = await UserSessionHelper.getEnterpriseId();
    WebSocketService().connect(
      userId: response['user_id']?.toString(),
      enterpriseId: enterpriseId?.toString(),
    );

    // Wipes the entire navigation stack — nothing to go back to
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const MainNavigation()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Button enabled when form is valid and not loading
    final bool buttonEnabled = _isFormValid && !_isLoading;

    return Scaffold(
      backgroundColor: AppColors.surface,
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

                Center(
                  child: Text(
                    'Welcome',
                    style: AppTypography.h1.copyWith(
                      fontSize: 26,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(height: 6),

                Center(
                  child: Text(
                    'Login to continue',
                    style: AppTypography.bodySecondary.copyWith(
                      color: Colors.grey,
                    ),
                  ),
                ),

                const SizedBox(height: 40),

                Text(
                  'Username',
                  style: AppTypography.bodyPrimary.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),

                TextFormField(
                  controller: _usernameController,
                  inputFormatters: [
                    FilteringTextInputFormatter.deny(RegExp(r'\s')),
                  ],
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
                  validator: (v) => Validators.validateRequired(v, 'Username'),
                ),

                const SizedBox(height: 20),

                Text(
                  'Password',
                  style: AppTypography.bodyPrimary.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),

                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  inputFormatters: [
                    FilteringTextInputFormatter.deny(RegExp(r'\s')),
                  ],
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
                  validator: (v) => Validators.validateRequired(v, 'Password'),
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
                      child: Text(
                        'Forgot Password?',
                        style: AppTypography.bodyPrimary.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                AppButton(
                  label: 'Login',
                  onPressed: buttonEnabled ? _login : null,
                  loading: _isLoading,
                  height: 55,
                ),

                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}