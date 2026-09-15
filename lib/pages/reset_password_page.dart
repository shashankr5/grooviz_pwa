import 'package:flutter/material.dart';
import '../services/login_service.dart';

import '../theme/app_typography.dart';
import '../theme/app_colors.dart';
import '../utils/validators.dart';
import 'login_page.dart';

class ResetPasswordPage extends StatefulWidget {
  final String mobile;

  const ResetPasswordPage({super.key, required this.mobile});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final TextEditingController _newPassController = TextEditingController();
  final TextEditingController _confirmPassController = TextEditingController();
  bool _isLoading = false;
  bool _obscure1 = true;
  bool _obscure2 = true;

  Future<void> _resetPassword() async {
    final passError = Validators.validatePassword(_newPassController.text.trim(), minLength: 4);
    if (passError != null) {
      _showMessage(passError, false);
      return;
    }
    final matchError = Validators.validateConfirmPassword(_confirmPassController.text, _newPassController.text);
    if (matchError != null) {
      _showMessage(matchError, false);
      return;
    }

    setState(() => _isLoading = true);

    final res = await LoginService().resetPassword(
      mobile: widget.mobile,
      newPassword: _newPassController.text.trim(),
    );

    setState(() => _isLoading = false);

    _showMessage(res["message"], res["success"]);

    if (res["success"]) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    }
  }

  void _showMessage(String msg, bool success) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: success ? AppColors.secondary : AppColors.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Reset Password", style: AppTypography.appBarTitle),
      ),
      backgroundColor: Colors.white,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Create a new password",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 24),

            _buildPasswordField(
              controller: _newPassController,
              obscureText: _obscure1,
              toggle: () => setState(() => _obscure1 = !_obscure1),
              hint: "New Password",
            ),

            const SizedBox(height: 20),

            _buildPasswordField(
              controller: _confirmPassController,
              obscureText: _obscure2,
              toggle: () => setState(() => _obscure2 = !_obscure2),
              hint: "Confirm Password",
            ),

            const SizedBox(height: 30),

            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _resetPassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  disabledBackgroundColor: Colors.grey.shade400,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        "Reset Password",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPasswordField({
    required TextEditingController controller,
    required bool obscureText,
    required VoidCallback toggle,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(
            obscureText ? Icons.visibility_off : Icons.visibility,
          ),
          onPressed: toggle,
        ),
        filled: true,
        fillColor: AppColors.bgLight,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }
}


