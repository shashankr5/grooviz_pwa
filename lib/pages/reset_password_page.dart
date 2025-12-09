import 'package:flutter/material.dart';
import '../services/login_service.dart';
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
    if (_newPassController.text.trim().length < 4) {
      _showMessage("Password must be at least 4 characters", false);
      return;
    }
    if (_newPassController.text != _confirmPassController.text) {
      _showMessage("Passwords do not match", false);
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
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text("Reset Password",
            style: TextStyle(color: Colors.black)),
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
                  backgroundColor: const Color(0xFFFFC107),
                  disabledBackgroundColor: Colors.grey.shade400,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.black)
                    : const Text(
                        "Reset Password",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: Colors.black87,
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
        fillColor: Colors.grey.shade100,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              const BorderSide(color: Color(0xFFFFC107), width: 1.5),
        ),
      ),
    );
  }
}
