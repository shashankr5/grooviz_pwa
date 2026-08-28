// main_navigation.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'home_page.dart';
import 'tasks_page.dart';
import 'food_orders_page.dart';
import 'camera_content_page.dart';
import 'login_page.dart';
import 'profile_page.dart';
import '../utils/notification_permission_manager.dart';
import '../utils/user_session_helper.dart';
import '../services/logout_service.dart';

import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../services/role_change_watcher.dart';
import '../services/session_change_service.dart';
import '../services/websocket_service.dart';
import '../services/profile_service.dart';

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  /// Called externally (e.g. from notification tap) to switch to a named tab.
  /// Keys: 'home', 'food', 'tasks', 'camera'.
  static void Function(String tabKey)? tabSwitchCallback;

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  List<String> _departments = [];
  String _userRole = '';
  bool _isLoadingDepts = true;

  late final RoleChangeWatcher _roleWatcher;
  StreamSubscription<String>? _sessionChangeSub;

  final GlobalKey<HomePageState>       _homeKey     = GlobalKey<HomePageState>();
  final GlobalKey<FoodOrdersPageState> _foodKey     = GlobalKey<FoodOrdersPageState>();
  final GlobalKey<TasksPageState>      _tasksKey    = GlobalKey<TasksPageState>();

  // ── Nav config ────────────────────────────────────────────────────────────

  late final List<_NavEntry> _allNavItems = [
    _NavEntry(
      key: 'home',
      page: HomePage(key: _homeKey),
      item: const BottomNavigationBarItem(
        icon: Icon(Icons.home_outlined, size: 26),
        activeIcon: Icon(Icons.home, size: 26),
        label: 'Home',
      ),
    ),
    _NavEntry(
      key: 'food',
      page: FoodOrdersPage(key: _foodKey),
      item: const BottomNavigationBarItem(
        icon: Icon(Icons.fastfood_outlined, size: 26),
        activeIcon: Icon(Icons.fastfood, size: 26),
        label: 'Food',
      ),
    ),
    _NavEntry(
      key: 'tasks',
      page: TasksPage(key: _tasksKey),
      item: const BottomNavigationBarItem(
        icon: Icon(Icons.task_alt_outlined, size: 26),
        activeIcon: Icon(Icons.task_alt, size: 26),
        label: 'My Tasks',
      ),
    ),
    const _NavEntry(
      key: 'camera',
      page: CameraContentPage(key: PageStorageKey('camera')),
      item: BottomNavigationBarItem(
        icon: Icon(Icons.camera_alt_outlined, size: 26),
        activeIcon: Icon(Icons.camera_alt, size: 26),
        label: 'Camera',
      ),
    ),
    const _NavEntry(
      key: 'profile',
      page: ProfilePage(),
      item: BottomNavigationBarItem(
        icon: Icon(Icons.person_outline_rounded, size: 26),
        activeIcon: Icon(Icons.person_rounded, size: 26),
        label: 'Profile',
      ),
    ),
  ];

  // ── Department → visible tab keys ─────────────────────────────────────────
  //
  // Each department is mapped to exactly the tabs its staff need.
  // Fuzzy matching handles casing/spacing variants from the server.
  // Management roles (Manager, GM, Admin) bypass dept restrictions
  // and see every tab so they can supervise the full operation.

  Set<String> _tabsForDepartment(String dept) {
    final d = dept.trim().toLowerCase();

    // ── Food & Beverage ───────────────────────────────────────────────────
    // F&B staff work on the Food tab; they don't handle service requests
    // or room deliveries directly. They now also have access to their profile.
    if (d == 'food & beverage' ||
        d == 'food and beverage' ||
        d == 'f&b' ||
        d == 'fnb' ||
        d.contains('food') && d.contains('beverage')) {
      return {'food', 'tasks', 'profile'};
    }

    // ── Front Office ──────────────────────────────────────────────────────
    // Front-desk staff handle service requests and can view guest camera
    // content. They don't handle food orders or room-service deliveries.
    if (d == 'front office' ||
        d == 'frontoffice' ||
        d == 'front desk' ||
        d == 'frontdesk' ||
        d.contains('front') && d.contains('office')) {
      return {'home', 'tasks', 'camera'};
    }

    // ── Room Service ──────────────────────────────────────────────────────
    // Room-service staff deliver food orders and handle service requests.
    if (d.contains('room') && d.contains('service') ||
        d == 'roomservice') {
      return {'home', 'tasks'};
    }

    // ── Housekeeping ──────────────────────────────────────────────────────
    if (d == 'housekeeping' ||
        d == 'house keeping' ||
        d.contains('housekeep') ||
        d.contains('house keep')) {
      return {'home', 'tasks'};
    }

    // ── Maintenance / Engineering ─────────────────────────────────────────
    if (d == 'maintenance' ||
        d == 'engineering' ||
        d.contains('mainten') ||
        d.contains('engineer')) {
      return {'home', 'tasks'};
    }

    // ── IT ────────────────────────────────────────────────────────────────
    if (d == 'it' ||
        d == 'information technology' ||
        d.contains('informat') && d.contains('tech')) {
      return {'home', 'tasks'};
    }

    // ── Recreation / Spa / Leisure ────────────────────────────────────────
    if (d == 'recreation' ||
        d == 'spa' ||
        d == 'leisure' ||
        d == 'gym' ||
        d.contains('recreat') ||
        d.contains('wellness')) {
      return {'home', 'tasks'};
    }

    // ── Laundry ───────────────────────────────────────────────────────────
    if (d == 'laundry' || d.contains('laundr')) {
      return {'home', 'tasks'};
    }

    // ── Security ──────────────────────────────────────────────────────────
    if (d == 'security' || d.contains('securit')) {
      return {'home', 'tasks'};
    }

    // ── Concierge / Guest Relations ───────────────────────────────────────
    if (d == 'concierge' ||
        d == 'guest relations' ||
        d == 'guest services' ||
        d.contains('concierge') ||
        d.contains('guest relat')) {
      return {'home', 'tasks', 'camera'};
    }

    // ── Default: any unrecognised department sees the core tabs ───────────
    return {'home', 'tasks'};
  }

  List<String> get _visibleKeys {
    // Management roles (Manager, GM, Admin) are not restricted by department —
    // they supervise all operations and need every tab.
    const managementRoles = {
      'admin', 'general manager', 'manager',
    };
    if (managementRoles.contains(_userRole.trim().toLowerCase())) {
      // Management sees all tabs except the profile tab (they always have Home).
      return _allNavItems.map((e) => e.key).where((k) => k != 'profile').toList();
    }

    // No departments stored yet — show minimal set while loading.
    if (_departments.isEmpty) return ['home', 'tasks'];

    // Union the allowed tabs across all of the user's departments.
    final allowed = <String>{};
    for (final dept in _departments) {
      allowed.addAll(_tabsForDepartment(dept));
    }

    // If the user has no 'home' tab, replace it with 'profile' so they
    // still have access to their info and logout.
    if (!allowed.contains('home')) {
      allowed.add('profile');
    }

    // Preserve the canonical ordering defined in _allNavItems.
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
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _reconnectWebSocket(); // Fix Bug 1: Ensure WebSocket connects unconditionally on MainNavigation mount

    // Register tab-switch callback so external callers (notification taps)
    // can switch the active tab without needing direct widget tree access.
    MainNavigation.tabSwitchCallback = switchToTab;

    _roleWatcher = RoleChangeWatcher(onRoleChanged: _onRoleChanged);
    _roleWatcher.startWatching();

    // Seed the role/dept baseline immediately on startup, then load departments.
    _seedBaselineIfNeeded();

    // Listen for role/dept changes so we can react instantly on this navigator
    _sessionChangeSub =
        SessionChangeService.instance.onRoleChange.listen((_) {
      _onRoleChanged();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _roleWatcher.stopWatching();
    _sessionChangeSub?.cancel();
    MainNavigation.tabSwitchCallback = null;
    super.dispose();
  }

  void _refreshCurrentTab(int index) {
    final entries = _activeEntries;
    if (index < 0 || index >= entries.length) return;
    final key = entries[index].key;
    if (key == 'home') {
      _homeKey.currentState?.refreshData();
    } else if (key == 'food') {
      _foodKey.currentState?.refreshData();
    } else if (key == 'tasks') {
      _tasksKey.currentState?.refreshData();
    }
  }

  /// Switches to the named tab key ('home', 'food', 'tasks', etc.).
  /// Safely ignored if the key is not visible for the current user's role.
  void switchToTab(String tabKey) {
    final entries = _activeEntries;
    final idx = entries.indexWhere((e) => e.key == tabKey);
    if (idx == -1 || !mounted) return;
    setState(() => _currentIndex = idx);
    _refreshCurrentTab(idx);
  }

  void _onTabTapped(int index) {
    if (_currentIndex == index) {
      // Tapping the already-active tab: do NOT re-fetch data.
      // Refreshing on same-tab tap causes _loadDeliveryCounts → resetDeliveryCount(0)
      // → _reevaluate which previously re-triggered the foreground alert service.
      // Standard bottom-nav UX: active-tab tap is a no-op (or scroll-to-top via page key).
      return;
    }
    setState(() => _currentIndex = index);
    _refreshCurrentTab(index);
  }

  // Guards didChangeAppLifecycleState against notification-shade pulls.
  bool _didPause = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _didPause = true;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_didPause) return; // shade pull: inactive→resumed, skip
      _didPause = false;
      // Reload departments on resume in case they changed server-side
      _loadDepartments();
      // FIX-9 (Bug 9): connect() has a same-credentials + isConnected guard,
      // so this is a cheap no-op if already connected — but re-establishes
      // the socket if it dropped while backgrounded.
      _reconnectWebSocket();
    }
  }

  /// Seeds role + departments into SharedPreferences from the server if they
  /// are not already present, and then loads departments. Sequenced to avoid
  /// race conditions between initial write and read.
  Future<void> _seedBaselineIfNeeded() async {
    final existingRole  = await UserSessionHelper.getRole();
    final existingDepts = await UserSessionHelper.getDepartments();

    final initRole  = await UserSessionHelper.getInitialRole();
    final initDepts = await UserSessionHelper.getInitialDepartments();

    if (existingRole == null || existingDepts.isEmpty) {
      debugPrint('[MainNavigation] Baseline missing — seeding from getProfile()...');
      try {
        final result = await ProfileService().getProfile();
        if (result['success'] == true) {
          final profile = result['profile'] as Map<String, dynamic>?;
          final role = profile?['role']?.toString() ?? '';
          debugPrint('[MainNavigation] Baseline seeded: role="$role" departments=${profile?['departments']}');

          List<String> deptList = [];
          final rawDepts = profile?['departments'];
          if (rawDepts is String) {
            deptList = List<String>.from(jsonDecode(rawDepts));
          } else if (rawDepts is List) {
            deptList = List<String>.from(rawDepts);
          }

          if (initRole == null && role.isNotEmpty) {
            await UserSessionHelper.saveInitialRole(role);
          }
          if (initDepts.isEmpty && deptList.isNotEmpty) {
            await UserSessionHelper.saveInitialDepartments(deptList);
          }
        } else {
          debugPrint('[MainNavigation] getProfile() failed during baseline seed: ${result['message']}');
        }
      } catch (e) {
        debugPrint('[MainNavigation] _seedBaselineIfNeeded error (non-fatal): $e');
      }
    } else {
      if (initRole == null) {
        await UserSessionHelper.saveInitialRole(existingRole);
      }
      if (initDepts.isEmpty) {
        await UserSessionHelper.saveInitialDepartments(existingDepts);
      }
      debugPrint('[MainNavigation] Baseline already seeded: role="$existingRole" depts=$existingDepts');
    }

    await _loadDepartments(); // Read departments only after baseline seed check is complete
  }

  Future<void> _reconnectWebSocket() async {
    final userId = await UserSessionHelper.getUserId();
    final enterpriseId = await UserSessionHelper.getEnterpriseId();
    if (userId == null || enterpriseId == null) return;
    WebSocketService().connect(
      userId: userId.toString(),
      enterpriseId: enterpriseId.toString(),
    );
  }

  Future<void> _loadDepartments() async {
    final depts = await UserSessionHelper.getDepartments();
    final role  = await UserSessionHelper.getRole();
    if (mounted) {
      setState(() {
        _departments    = depts;
        _userRole       = role ?? '';
        _isLoadingDepts = false;
        // Clamp index to valid range after dept/role change
        final entries = _activeEntries;
        if (_currentIndex >= entries.length) _currentIndex = 0;
      });
    }
  }

  Future<void> _requestPermissions() async {
    // Wait for the first frame so we have a valid BuildContext for the sheet.
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    await NotificationPermissionManager.requestAllPermissions(context);
  }

  // ── Role / dept changed ───────────────────────────────────────────────────

  bool _isShowingRoleChangedSheet = false;

  /// Called by RoleChangeWatcher or WebSocket after session invalidation.
  /// Shows an un-dismissible bottom sheet explaining what changed,
  /// with a single "Log Out" button.
  void _onRoleChanged() {
    if (!mounted || _isShowingRoleChangedSheet) return;
    _isShowingRoleChangedSheet = true;

    final reason = SessionChangeService.instance.changeReason;

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag:    false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _RoleChangedSheet(
        reason:   reason,
        onLogout: () async {
          await LogoutService().logout();
          _navigateToLogin();
        },
      ),
    );
  }

  void _navigateToLogin() {
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder:        (_, __, ___) => const LoginPage(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
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

    final entries   = _activeEntries;
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
            topLeft:  Radius.circular(24),
            topRight: Radius.circular(24),
          ),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset:     const Offset(0, -3),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex:         safeIndex,
          backgroundColor:      Colors.transparent,
          elevation:            0,
          type:                 BottomNavigationBarType.fixed,
          selectedFontSize:     12,
          unselectedFontSize:   12,
          selectedItemColor:    AppColors.primary,
          unselectedItemColor:  AppColors.textSecondary,
          selectedIconTheme:    const IconThemeData(size: 28),
          unselectedIconTheme:  const IconThemeData(size: 24),
          showSelectedLabels:   true,
          showUnselectedLabels: true,
          onTap: _onTabTapped,
          items: entries.map((e) => e.item).toList(),
        ),
      ),
    );
  }
}

// ── Role Changed Bottom Sheet ─────────────────────────────────────────────────

class _RoleChangedSheet extends StatelessWidget {
  final String       reason;
  final VoidCallback onLogout;

  const _RoleChangedSheet({
    required this.reason,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 24),
              width:  36,
              height: 4,
              decoration: BoxDecoration(
                color:        AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Icon
            Container(
              padding: const EdgeInsets.all(18),
              decoration: const BoxDecoration(
                color: AppColors.warningLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.manage_accounts_rounded,
                color: AppColors.warning,
                size:  36,
              ),
            ),
            const SizedBox(height: 18),

            // Title
            const Text(
              'Account Updated',
              style: AppTypography.title,
            ),
            const SizedBox(height: 10),

            // Specific reason
            Text(
              reason,
              textAlign: TextAlign.center,
              style: AppTypography.bodySecondary.copyWith(height: 1.5),
            ),
            const SizedBox(height: 6),

            // Sub-text
            const Text(
              'Please log in again to continue with your updated access.',
              textAlign: TextAlign.center,
              style: AppTypography.bodySecondary,
            ),
            const SizedBox(height: 28),

            // Log Out button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onLogout,
                icon:  const Icon(Icons.logout_rounded, size: 18),
                label: Text(
                  'Log Out',
                  style: AppTypography.buttonLabel.copyWith(color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation:       0,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Simple data class ─────────────────────────────────────────────────────────

class _NavEntry {
  final String                  key;
  final Widget                  page;
  final BottomNavigationBarItem item;

  const _NavEntry({
    required this.key,
    required this.page,
    required this.item,
  });
}