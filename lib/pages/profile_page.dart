import 'dart:convert';
import 'package:flutter/material.dart';

import '../services/profile_service.dart';
import '../services/logout_service.dart';
import '../services/order_alert_service.dart';
import '../utils/user_session_helper.dart';

import '../theme/app_typography.dart';
import '../theme/app_colors.dart';

import '../components/app_dialog.dart';

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

  String name           = "";
  String role           = "";
  String designation    = "";
  String email          = "";
  String phone          = "";
  String enterpriseName = "";
  List<String> departments = [];
  int userId = 0;

  /// Show up to 4 departments before scrolling kicks in.
  static const int _maxVisibleDepts = 4;

  /// Approximate height per department chip (padding + text + margin).
  static const double _chipHeight = 36.0;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final local = await UserSessionHelper.getSafeUserProfile();

    if (local != null) {
      _setProfileData(local);
      setState(() => _isLoading = false);
      print("✅ Loaded profile from SAFE cache");
    }

    print("🌐 Refreshing profile from API");
    final result = await ProfileService().getProfile();

    if (!mounted) return;

    if (!result["success"]) {
      if (local == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result["message"]),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    final profile = result["profile"];
    await UserSessionHelper.saveUserProfile(profile);
    _setProfileData(profile);
    setState(() => _isLoading = false);
  }

  void _setProfileData(Map<String, dynamic> profile) {
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
      userId        = profile["user_id"] ?? 0;
      name          = profile["name"] ?? "";
      role          = profile["role"] ?? "";
      designation   = profile["designation"] ?? "";
      email         = profile["email"] ?? "";
      phone         = profile["phone_number"] ?? "";
      enterpriseName = (profile["enterprise_name"] ?? "").toString().trim();
      departments   = deptList;
    });
  }

  Future<void> _handleLogout(BuildContext context) async {
    // Button press animation
    setState(() => _isPressed = true);
    await Future.delayed(const Duration(milliseconds: 150));
    setState(() => _isPressed = false);

    if (!mounted) return;

    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.logout_rounded,
                        color: AppColors.error, size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    "Log Out?",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                "You'll need to log in again to access your tasks.",
                style: AppTypography.bodySecondary.copyWith(fontSize: 14),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.border),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text("Cancel",
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.error,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text("Log Out",
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirm != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );

    final result = await LogoutService().logout();
    await OrderAlertService.stop();

    if (mounted) {
      Navigator.of(context).pop();
    }

    if (!result["success"]) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result["message"]),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result["message"]),
          backgroundColor: Colors.green,
        ),
      );

      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => const LoginPage(),
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
        (route) => false,
      );
    }
  }

  Widget _circleIcon(IconData icon, Color iconColor, Color bgColor) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
      child: Icon(icon, color: iconColor, size: 22),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppColors.primary, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value.isNotEmpty ? value : "—",
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _departmentChip(String dept) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              dept,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                fontSize: 13,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dotGrid() {
    const int cols = 4;
    const int rows = 4;
    const double spacing = 6.0;
    const double dotSize = 3.5;

    return SizedBox(
      width: cols * (dotSize + spacing),
      height: rows * (dotSize + spacing),
      child: Column(
        children: List.generate(rows, (r) {
          return Row(
            children: List.generate(cols, (c) {
              return Container(
                width: dotSize,
                height: dotSize,
                margin: const EdgeInsets.all(spacing / 2),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.18),
                  shape: BoxShape.circle,
                ),
              );
            }),
          );
        }),
      ),
    );
  }

  /// Builds the departments section:
  /// - If ≤ 4 departments → column with natural height.
  /// - If > 4 → fixed-height scrollable list showing 4 items at a time.
  Widget _buildDepartmentsSection() {
    if (departments.isEmpty) {
      return Text(
        "—",
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      );
    }

    final int deptCount = departments.length;
    final bool needsScroll = deptCount > _maxVisibleDepts;

    if (needsScroll) {
      // Fixed height showing exactly _maxVisibleDepts items, scroll for the rest
      final double scrollHeight = _maxVisibleDepts * _chipHeight;
      return SizedBox(
        height: scrollHeight,
        child: ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: deptCount,
          itemBuilder: (_, i) => _departmentChip(departments[i]),
        ),
      );
    } else {
      // Natural height – no scroll needed
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: departments.map(_departmentChip).toList(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: AppBar(
        title: const Text("Profile", style: AppTypography.appBarTitle),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ─────────────────── PROFILE CARD ───────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Avatar + Name ──
                  Stack(
                    children: [
                      Positioned(
                        right: 0,
                        top: 0,
                        child: _dotGrid(),
                      ),
                      Row(
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: AppColors.primary.withOpacity(0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                name.isNotEmpty
                                    ? name.substring(0, 1).toUpperCase()
                                    : "?",
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 26,
                                  fontWeight: FontWeight.w700,
                                ),
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
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  designation,
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Divider(color: AppColors.border),
                  const SizedBox(height: 20),

                  // ── Info + Departments (Dynamic height & divider) ──
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // LEFT: contact info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _infoRow(Icons.email_outlined, "Email", email),
                              const SizedBox(height: 14),
                              _infoRow(Icons.phone_outlined, "Phone", phone),
                              if (role.isNotEmpty) ...[
                                const SizedBox(height: 14),
                                _infoRow(Icons.badge_outlined, "Role", role),
                              ],
                              if (enterpriseName.isNotEmpty) ...[
                                const SizedBox(height: 14),
                                _infoRow(Icons.business_outlined, "Enterprise", enterpriseName),
                              ],
                            ],
                          ),
                        ),

                        // VERTICAL DIVIDER – automatically matches tallest column
                        Container(
                          width: 1,
                          height: double.infinity,
                          color: AppColors.border,
                          margin: const EdgeInsets.symmetric(horizontal: 12),
                        ),

                        // RIGHT: departments (scrollable after 4)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(
                                      Icons.grid_view_rounded,
                                      color: AppColors.primary,
                                      size: 16,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    "Departments",
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              _buildDepartmentsSection(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ─────────────────── SETTINGS CARD ───────────────────
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
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.lock_outline_rounded,
                        color: AppColors.primary,
                        size: 20,
                      ),
                    ),
                    title: const Text(
                      "Privacy",
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text("Security and privacy settings"),
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

            // ─────────────────── LOGOUT BUTTON ───────────────────
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
                  color: Colors.white,
                  border: Border.all(
                    color: _isPressed
                        ? AppColors.primaryDark
                        : AppColors.primary,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.logout,
                      color: _isPressed
                          ? AppColors.primaryDark
                          : AppColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "Log Out",
                      style: TextStyle(
                        fontSize: 16,
                        color: _isPressed
                            ? AppColors.primaryDark
                            : AppColors.primary,
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

