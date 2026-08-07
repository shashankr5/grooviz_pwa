import 'package:flutter/material.dart';
import '../utils/user_session_helper.dart';
import '../services/login_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import 'otp_verify_page.dart';
import 'reset_password_page.dart';

class PasswordSecurityPage extends StatefulWidget {
  const PasswordSecurityPage({super.key});

  @override
  State<PasswordSecurityPage> createState() => _PasswordSecurityPageState();
}

class _PasswordSecurityPageState extends State<PasswordSecurityPage> {
  String username = "";
  String mobile = ""; // needed for reset API
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final profile = await UserSessionHelper.getUserProfile();

    final savedName = await UserSessionHelper.getUserName();
    final savedPhone = await UserSessionHelper.getPhone();

    setState(() {
        // ✅ Priority: session → profile → fallback
        username =
            savedName ??
            profile?["name"] ??
            profile?["full_name"] ??
            "User";

        mobile =
            savedPhone ??
            profile?["phone_number"] ??
            profile?["phone"] ??
            "";

        _isLoading = false;
    });

    print("🔥 Username: $username");
    print("🔥 Mobile: $mobile");
  }

  String _maskedPassword() {
    return "••••••••"; // never show real password
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: AppBar(
        title: const Text("Password & Login", style: AppTypography.appBarTitle),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(20), // ✅ updated padding
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border), // optional but recommended
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black12.withOpacity(0.05), // ✅ improved shadow
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        _infoTile(
                          icon: Icons.person_outline,
                          title: "Username",
                          value: username,
                        ),
                        const Divider(),

                        _infoTile(
                          icon: Icons.lock_outline,
                          title: "Password",
                          value: _maskedPassword(),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  /// 🔥 Reset Button
                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton(
                    onPressed: () async {
                      if (mobile.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Phone number not available"),
                          ),
                        );
                        return;
                      }

                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Sending OTP code...")),
                      );

                      final result = await LoginService().sendOtp(mobile: mobile);
                      if (!context.mounted) return;

                      if (result['success'] == true) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => OtpVerifyPage(mobile: mobile),
                          ),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(result['message'] ?? 'Failed to send OTP'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                      style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      "Reset Password",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
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

  Widget _infoTile({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(value),
    );
  }
}

