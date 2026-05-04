// main_navigation.dart
import 'package:flutter/material.dart';
import 'home_page.dart';
import 'tasks_page.dart';
import 'profile_page.dart';
import 'food_orders_page.dart';
import 'camera_content_page.dart';
import 'login_page.dart';
import '../utils/notification_permission_manager.dart';
import '../utils/user_session_helper.dart';
import '../utils/app_colors.dart';
import '../services/role_change_watcher.dart';

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;
  List<String> _departments = [];
  bool _isLoadingDepts = true;

  late final RoleChangeWatcher _roleWatcher;

  // ── Nav config ────────────────────────────────────────────────────────────
  // Each entry pairs a page widget with its BottomNavigationBarItem.
  // We build the active subset from this master list at render time.

  static const _allNavItems = [
    _NavEntry(
      key: 'home',
      page: HomePage(key: PageStorageKey('home')),
      item: BottomNavigationBarItem(
        icon: Icon(Icons.home_outlined, size: 26),
        activeIcon: Icon(Icons.home, size: 26),
        label: 'Home',
      ),
    ),
    _NavEntry(
      key: 'food',
      page: FoodOrdersPage(key: PageStorageKey('food')),
      item: BottomNavigationBarItem(
        icon: Icon(Icons.fastfood_outlined, size: 26),
        activeIcon: Icon(Icons.fastfood, size: 26),
        label: 'Food',
      ),
    ),
    _NavEntry(
      key: 'tasks',
      page: TasksPage(key: PageStorageKey('tasks')),
      item: BottomNavigationBarItem(
        icon: Icon(Icons.task_alt_outlined, size: 26),
        activeIcon: Icon(Icons.task_alt, size: 26),
        label: 'My Tasks',
      ),
    ),
    _NavEntry(
      key: 'profile',
      page: ProfilePage(key: PageStorageKey('profile')),
      item: BottomNavigationBarItem(
        icon: Icon(Icons.person_outline, size: 26),
        activeIcon: Icon(Icons.person, size: 26),
        label: 'Profile',
      ),
    ),
    _NavEntry(
      key: 'camera',
      page: CameraContentPage(key: PageStorageKey('camera')),
      item: BottomNavigationBarItem(
        icon: Icon(Icons.camera_alt_outlined, size: 26),
        activeIcon: Icon(Icons.camera_alt, size: 26),
        label: 'Camera',
      ),
    ),
  ];

  // ── Department → visible tab keys ─────────────────────────────────────────

  Set<String> _tabsForDepartment(String dept) {
    final d = dept.trim().toLowerCase();

    if (d == 'food & beverage') {
      return {'food', 'profile'};
    }

    if (d == 'front office') {
      return {'home', 'tasks', 'camera'};
    }

    if (d == 'it' ||
        d == 'house keeping' ||
        d == 'maintenance' ||
        (d.contains('room') && d.contains('service'))) {
      return {'home', 'tasks'};
    }

    // Unrecognised department → full access
    return {'home', 'food', 'tasks', 'camera'};
  }

  List<String> get _visibleKeys {
    if (_departments.isEmpty) {
      return ['home', 'tasks'];
    }

    final allowed = <String>{};
    for (final dept in _departments) {
      allowed.addAll(_tabsForDepartment(dept));
    }

    // Profile tab is only for users with no home page access.
    // Everyone else reaches profile via the home page AppBar icon.
    if (allowed.contains('home')) {
      allowed.remove('profile');
    }

    return _allNavItems
        .map((e) => e.key)
        .where((key) => allowed.contains(key))
        .toList();
  }

  List<_NavEntry> get _activeEntries =>
      _allNavItems.where((e) => _visibleKeys.contains(e.key)).toList();

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadDepartments();
    _requestPermissions();

    // Auto-logout when role/department changes on the server.
    // Fires on every app resume (foreground event).
    _roleWatcher = RoleChangeWatcher(
      onRoleChanged: _forceLogout,
    );
    _roleWatcher.startWatching();
  }

  @override
  void dispose() {
    _roleWatcher.stopWatching();
    super.dispose();
  }

  Future<void> _loadDepartments() async {
    final depts = await UserSessionHelper.getDepartments();
    if (mounted) {
      setState(() {
        _departments = depts;
        _isLoadingDepts = false;
        _currentIndex = 0; // reset index whenever tabs change
      });
    }
  }

  Future<void> _requestPermissions() async {
    await Future.delayed(const Duration(milliseconds: 500));
    await NotificationPermissionManager.requestAllNotificationPermissions();
  }

  // ── Force logout (called by RoleChangeWatcher) ────────────────────────────

  void _forceLogout() {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Your role has been updated. Please log in again.',
        ),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 4),
      ),
    );

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isLoadingDepts) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final entries = _activeEntries;

    // Guard: clamp index in case the tab list shrank
    final safeIndex = _currentIndex.clamp(0, entries.length - 1);

    return Scaffold(
      body: IndexedStack(
        index: safeIndex,
        children: entries.map((e) => e.page).toList(),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.bgLight,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: safeIndex,
          backgroundColor: Colors.transparent,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          selectedFontSize: 12,
          unselectedFontSize: 12,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.textSecondary,
          selectedIconTheme: const IconThemeData(size: 28),
          unselectedIconTheme: const IconThemeData(size: 24),
          showSelectedLabels: true,
          showUnselectedLabels: true,
          onTap: (index) => setState(() => _currentIndex = index),
          items: entries.map((e) => e.item).toList(),
        ),
      ),
    );
  }
}

// ── Simple data class to pair a page with its nav item ────────────────────────

class _NavEntry {
  final String key;
  final Widget page;
  final BottomNavigationBarItem item;

  const _NavEntry({
    required this.key,
    required this.page,
    required this.item,
  });
}