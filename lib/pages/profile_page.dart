// profile_page.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'login_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _isPressed = false;
  bool _isLoading = true;
  String? _errorMessage;

  // Profile data
  String _name = '';
  String _designation = '';
  String _email = '';
  String _phone = '';
  List<String> _departments = [];

  // === CONFIG: replace these with your real endpoints ===
  static const String _profileApiUrl = ' https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production/ScreenSync_get_profile_mobile';
  static const String _logoutApiUrl = 'https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production/ScreenSync_logout_mobile';
  // =====================================================

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  String getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.isNotEmpty ? parts.first[0].toUpperCase() : '?';
    }
    final first = parts.first[0];
    final last = parts.last.isNotEmpty ? parts.last[0] : '';
    return (first + last).toUpperCase();
  }

  Color getStableRandomColor(String name) {
    final hash = name.hashCode;
    final r = (hash & 0xFF0000) >> 16;
    final g = (hash & 0x00FF00) >> 8;
    final b = (hash & 0x0000FF);
    final rr = (r.abs()) % 256;
    final gg = (g.abs()) % 256;
    final bb = (b.abs()) % 256;
    return Color.fromARGB(255, rr, gg, bb).withOpacity(0.9);
  }

  Future<void> _loadProfile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('user_id');

      if (userId == null) {
        setState(() {
          _errorMessage = 'User not logged in';
          _isLoading = false;
        });
        return;
      }

      final response = await http.post(
        Uri.parse(_profileApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': userId}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        setState(() {
          _errorMessage = 'Server error: ${response.statusCode}';
          _isLoading = false;
        });
        return;
      }

      final jsonBody = jsonDecode(response.body);

      // Validate STATUS
      if (jsonBody is Map &&
          jsonBody['STATUS'] is List &&
          (jsonBody['STATUS'] as List).isNotEmpty &&
          jsonBody['STATUS'][0] is Map &&
          jsonBody['STATUS'][0]['status'] == 'S') {
        // OK
      } else {
        String msg = 'Failed to fetch profile';
        try {
          if (jsonBody is Map &&
              jsonBody['STATUS'] is List &&
              (jsonBody['STATUS'] as List).isNotEmpty &&
              jsonBody['STATUS'][0] is Map &&
              jsonBody['STATUS'][0]['message'] != null) {
            msg = jsonBody['STATUS'][0]['message'];
          }
        } catch (_) {}
        setState(() {
          _errorMessage = msg;
          _isLoading = false;
        });
        return;
      }

      // Extract RESULT array and first element safely
      if (jsonBody is Map &&
          jsonBody['RESULT'] is List &&
          (jsonBody['RESULT'] as List).isNotEmpty) {
        final dynamic rawData = (jsonBody['RESULT'] as List).first;
        if (rawData is Map) {
          final Map<String, dynamic> data = Map<String, dynamic>.from(rawData);

          // Parse departments — backend returns a JSON-encoded string, e.g. "[\"FRONT DESK\"]"
          List<String> deptList = [];
          final deptRaw = data['departments'];
          if (deptRaw is String) {
            try {
              final parsed = jsonDecode(deptRaw);
              if (parsed is List) {
                deptList = parsed.map((e) => e.toString()).toList();
              }
            } catch (_) {
              // fallback: try splitting by comma (unlikely), else keep empty
              deptList = [];
            }
          } else if (deptRaw is List) {
            deptList = deptRaw.map((e) => e.toString()).toList();
          }

          setState(() {
            _name = (data['name'] ?? '') as String;
            _designation = (data['designation'] ?? '') as String;
            _email = (data['email'] ?? '') as String;
            _phone = (data['phone_number'] ?? data['phone'] ?? '') as String;
            _departments = deptList;
            _isLoading = false;
            _errorMessage = null;
          });
          return;
        }
      }

      // If we reached here, RESULT was missing or malformed
      setState(() {
        _errorMessage = 'Invalid profile data';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Network error: $e';
        _isLoading = false;
      });
    }
  }

  void _handleLogout(BuildContext context) async {
    setState(() => _isPressed = true);
    await Future.delayed(const Duration(milliseconds: 150));
    setState(() => _isPressed = false);
    await Future.delayed(const Duration(milliseconds: 100));

    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('user_id');
    final installationId = prefs.getString('installation_id');

    if (userId == null || installationId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Invalid session data')));
      return;
    }

    final logoutBody = {'user_id': userId, 'installation_id': installationId};

    // show a simple progress indicator via a dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final response = await http.post(
        Uri.parse(_logoutApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(logoutBody),
      ).timeout(const Duration(seconds: 15));

      Navigator.of(context).pop(); // remove progress dialog

      if (response.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Server error: ${response.statusCode}')),
        );
        return;
      }

      final body = jsonDecode(response.body);

      final status = body is Map ? body['status'] as String? : null;
      final message = body is Map ? body['message'] as String? : null;

      if (status == 'S') {
        await prefs.clear(); // remove saved session details

        // navigate to login page
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 500),
            pageBuilder: (_, __, ___) => const LoginPage(),
            transitionsBuilder: (_, animation, __, child) =>
                FadeTransition(opacity: animation, child: child),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message ?? 'Logout failed')),
        );
      }
    } catch (e) {
      Navigator.of(context).pop(); // ensure progress dialog removed
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Logout error: $e')));
    }
  }

  Widget _buildProfileCard() {
    return Container(
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
                backgroundColor: getStableRandomColor(_name.isNotEmpty ? _name : 'user'),
                child: Text(
                  _name.isNotEmpty ? getInitials(_name) : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _name.isNotEmpty ? _name : '—',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _designation.isNotEmpty ? _designation : '—',
                    style: const TextStyle(
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
          // Contact & Departments
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // LEFT: Email & Phone (stacked)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Email',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _email.isNotEmpty ? _email : '—',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Phone',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _phone.isNotEmpty ? _phone : '—',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              // RIGHT: Departments
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Departments',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _departments.isNotEmpty
                        ? _departments
                            .map((dept) => Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Text(
                                    dept,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ))
                            .toList()
                        : [Text('—', style: TextStyle(color: Colors.grey.shade600))],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsCard() {
    return Container(
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
              'Notifications',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: const Text(
              'Manage notification preferences',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              // TODO: navigate to notifications settings
            },
          ),
          Divider(height: 1, color: Colors.grey.shade300),
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
              'Privacy',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: const Text(
              'Security and privacy settings',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              // TODO: navigate to privacy settings
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLogoutButton() {
    return GestureDetector(
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
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.logout,
                color: _isPressed ? Colors.white : Colors.red),
            const SizedBox(width: 8),
            Text(
              'Log Out',
              style: TextStyle(
                fontSize: 16,
                color: _isPressed ? Colors.white : Colors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfffaf8f5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Profile',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 22,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _loadProfile,
                          child: const Text('Retry'),
                        )
                      ],
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _buildProfileCard(),
                      const SizedBox(height: 20),
                      _buildSettingsCard(),
                      const SizedBox(height: 30),
                      _buildLogoutButton(),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
    );
  }
}
