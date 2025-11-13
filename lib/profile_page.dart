import 'package:flutter/material.dart';
import 'login_page.dart'; // Make sure you have your LoginPage imported

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _isPressed = false;

  void _handleLogout(BuildContext context) async {
    // Tap animation trigger
    setState(() => _isPressed = true);

    await Future.delayed(const Duration(milliseconds: 150));

    setState(() => _isPressed = false);

    // Add small delay for animation smoothness
    await Future.delayed(const Duration(milliseconds: 150));

    // Navigate to Login Page with fade transition
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 500),
      pageBuilder: (_, __, ___) => const LoginPage(),
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfffaf8f5), // light cream background
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

            /// -----------------------------------------
            /// PROFILE CARD
            /// -----------------------------------------
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

                  /// Row with avatar + name + designation
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: Colors.amber.shade600,
                        child: const Text(
                          "JD",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "John Doe",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            "Maintenance Staff",
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),
                  Divider(color: Colors.grey.shade300, thickness: 1),

                  const SizedBox(height: 18),

                  /// EMPLOYEE DETAILS
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Employee ID",
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            "HS-2024",
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),

                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Department",
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            "Maintenance",
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            /// -----------------------------------------
            /// NOTIFICATIONS & PRIVACY CARD
            /// -----------------------------------------
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

                  /// Notifications Row
                  ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.notifications_none,
                        color: Colors.amber.shade800,
                        size: 22,
                      ),
                    ),
                    title: const Text(
                      "Notifications",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      "Manage notification preferences",
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                  ),

                  Divider(height: 1, color: Colors.grey.shade300),

                  /// Privacy Row
                  ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.security,
                        color: Colors.grey.shade800,
                        size: 22,
                      ),
                    ),
                    title: const Text(
                      "Privacy",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      "Security and privacy settings",
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 30),

            /// -----------------------------------------
            /// LOGOUT BUTTON WITH TAP ANIMATION
            /// -----------------------------------------
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
                  color: _isPressed ? Colors.red.shade700 : Colors.white,
                  border: Border.all(
                    color: Colors.red.shade300,
                    width: 1.5,
                  ),
                  boxShadow: _isPressed
                      ? [
                          BoxShadow(
                            color: Colors.red.withOpacity(0.2),
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          )
                        ]
                      : [],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.logout,
                        color: _isPressed ? Colors.white : Colors.red),
                    const SizedBox(width: 8),
                    Text(
                      "Log Out",
                      style: TextStyle(
                        fontSize: 16,
                        color: _isPressed ? Colors.white : Colors.red,
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
