import 'dart:convert';
import 'package:flutter/material.dart';

import '../services/profile_service.dart';
import '../services/logout_service.dart';
import '../services/order_alert_service.dart';
import '../utils/user_session_helper.dart';

import 'login_page.dart';
import 'privacy_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _isPressed = false;
  bool _isLoading = true;

  String name = "";
  String designation = "";
  String email = "";
  String phone = "";
  List<String> departments = [];
  int userId = 0;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final service = ProfileService();
    final result = await service.getProfile();

    if (!mounted) return;

    if (!result["success"]) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result["message"]),
          backgroundColor: Colors.redAccent,
        ),
      );
      setState(() => _isLoading = false);
      return;
    }

    final profile = result["profile"];
    List<String> deptList = [];

    try {
      final raw = profile["departments"];
      if (raw is String) {
        deptList = List<String>.from(jsonDecode(raw));
      } else if (raw is List) {
        deptList = List<String>.from(raw);
      }
    } catch (_) {}

    setState(() {
      userId = profile["user_id"] ?? 0;
      name = profile["name"] ?? "";
      designation = profile["designation"] ?? "";
      email = profile["email"] ?? "";
      phone = profile["phone_number"] ?? "";
      departments = deptList;
      _isLoading = false;
    });
  }

  Future<void> _handleLogout(BuildContext context) async {
    setState(() => _isPressed = true);
    await Future.delayed(const Duration(milliseconds: 150));
    setState(() => _isPressed = false);

    final result = await LogoutService().logout();

    await OrderAlertService.stop();

    if (!mounted) return;

    if (!result["success"]) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result["message"]),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result["message"]),
        backgroundColor: Colors.green,
      ),
    );

    await Future.delayed(const Duration(milliseconds: 600));

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => const LoginPage(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Widget _circleIcon(IconData icon, Color iconColor, Color bgColor) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
      child: Icon(icon, color: iconColor, size: 22),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xfffaf8f5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          "Profile",
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 22,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ------------------------ PROFILE CARD ------------------------
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  )
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: Colors.amber.shade600,
                        child: Text(
                          name.isNotEmpty
                              ? name.substring(0, 1).toUpperCase()
                              : "?",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              designation,
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Divider(color: Colors.grey.shade300),
                  const SizedBox(height: 18),

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Email",
                                style: TextStyle(
                                    color: Colors.grey.shade600)),
                            const SizedBox(height: 4),
                            Text(
                              email,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 10),
                            Text("Phone",
                                style: TextStyle(
                                    color: Colors.grey.shade600)),
                            const SizedBox(height: 4),
                            Text(
                              phone,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 30),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Departments",
                                style: TextStyle(
                                    color: Colors.grey.shade600)),
                            const SizedBox(height: 4),
                            ...departments.map(
                                  (d) => Padding(
                                padding:
                                const EdgeInsets.only(bottom: 2),
                                child: Text(
                                  d,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // -------------------------- SETTINGS CARD --------------------------
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  )
                ],
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: _circleIcon(
                      Icons.security,
                      Colors.grey.shade800,
                      Colors.grey.shade200,
                    ),
                    title: const Text(
                      "Privacy",
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    subtitle:
                    const Text("Security and privacy settings"),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const PrivacyPage(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            // -------------------------- LOGOUT BUTTON --------------------------
            GestureDetector(
              onTap: () => _handleLogout(context),
              onTapDown: (_) => setState(() => _isPressed = true),
              onTapCancel: () => setState(() => _isPressed = false),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color:
                  _isPressed ? Colors.red.shade700 : Colors.white,
                  border: Border.all(
                      color: Colors.red.shade300, width: 1.5),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.logout,
                        color: _isPressed
                            ? Colors.white
                            : Colors.red),
                    const SizedBox(width: 8),
                    Text(
                      "Log Out",
                      style: TextStyle(
                        fontSize: 16,
                        color: _isPressed
                            ? Colors.white
                            : Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}