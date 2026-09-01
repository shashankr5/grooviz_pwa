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
import '../services/alert_reload_coordinator.dart';

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  /// Called externally (e.g. from notification tap) to switch to a named tab.
  /// Keys: 'home', 'food', 'tasks', 'camera', 'profile'.
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

  final GlobalKey<HomePageState>       _homeKey  = GlobalKey<HomePageState>();
  final GlobalKey<FoodOrdersPageState> _foodKey  = GlobalKey<FoodOrdersPageState>();
  final GlobalKey<TasksPageState>      _tasksKey = GlobalKey<TasksPageState>();

  // ── Nav config ────────────────────────────────────────────────────────────
  //
  // Tab visibility rules (nav bar only — Home page has its own in-page guards):
  //
  //  • Home      — all depts EXCEPT Food & Beverage
  //  • Food      — Food & Beverage only (+ management)
  //  • My Tasks  — every dept
  //  • Camera    — Front Office, Concierge / Guest Relations, management
  //  • Profile   — Food & Beverage only (they have no Home tab; others use
  //                the profile avatar in the Home AppBar)
  //
  // Delivery Queue and Report/Checkout are NOT nav-bar items.
  // They appear as cards / AppBar icons inside the Home page, conditionally
  // shown by home_page.dart based on the user's department.

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
  // Returns the set of nav-bar tab keys this department's staff should see.
  // Fuzzy matching handles casing / spacing variants from the server.

  Set<String> _tabsForDepartment(String dept) {
    final d = dept.trim().toLowerCase();

    // ── Food & Beverage ───────────────────────────────────────────────────
    // F&B staff use the Food tab and My Tasks. They have no Home page so
    // they get the Profile tab to access their info and log out.
    if (d == 'food & beverage' ||
        d == 'food and beverage' ||
        d == 'f&b' ||
        d == 'fnb' ||
        (d.contains('food') && d.contains('beverage'))) {
      return {'food', 'tasks', 'profile'};
    }

    // ── Front Office ──────────────────────────────────────────────────────
    // Front-desk staff see Home, My Tasks, and Camera. The Checkout/Report
    // button is shown inside the Home AppBar — not a separate nav tab.
    if (d == 'front office' ||
        d == 'frontoffice' ||
        d == 'front desk' ||
        d == 'frontdesk' ||
        (d.contains('front') && d.contains('office'))) {
      return {'home', 'tasks', 'camera'};
    }

    // ── Room Service ──────────────────────────────────────────────────────
    // Room-service staff handle deliveries. The Delivery Queue is shown as
    // a command card inside the Home page — not a separate nav tab.
    if ((d.contains('room') && d.contains('service')) ||
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
        (d.contains('informat') && d.contains('tech'))) {
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

    // ── Default: any unrecognised department gets the core tabs ───────────
    return {'home', 'tasks'};
  }

  List<String> get _visibleKeys {
    // Management roles bypass dept restrictions — they supervise everything.
    const managementRoles = {'admin', 'general manager', 'manager'};
    if (managementRoles.contains(_userRole.trim().toLowerCase())) {
      // Management always has Home, so no Profile tab needed.
      return _allNavItems
          .map((e) => e.key)
          .where((k) => k != 'profile')
          .toList();
    }

    // No departments stored yet — minimal fallback while still loading.
    if (_departments.isEmpty) return ['home', 'tasks'];

    // Union the allowed tabs across all of the user's departments.
    final allowed = <String>{};
    for (final dept in _departments) {
      allowed.addAll(_tabsForDepartment(dept));
    }

    // Profile tab is only shown when the user has NO home-giving department.
    // If any department grants 'home', remove 'profile' — the user reaches
    // their profile via the AppBar avatar on the Home page instead.
    // This handles multi-dept users (e.g. F&B + Room Service) correctly:
    // Room Service grants 'home', so 'profile' from F&B is stripped out.
    if (allowed.contains('home')) {
      allowed.remove('profile');
    } else if (!allowed.contains('profile')) {
      // Pure F&B (or any no-home dept) — ensure profile is reachable.
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
    _reconnectWebSocket();

    MainNavigation.tabSwitchCallback = switchToTab;

    _roleWatcher = RoleChangeWatcher(onRoleChanged: _onRoleChanged);
    _roleWatcher.startWatching();

    _seedBaselineIfNeeded();

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
      // Tapping the already-active tab is a no-op — avoids re-triggering
      // data loads / alert reconciliation on the same-tab tap.
      return;
    }
    setState(() => _currentIndex = index);
    _refreshCurrentTab(index);
  }

  bool _didPause = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _didPause = true;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_didPause) return; // notification-shade pull: skip
      _didPause = false;
      _loadDepartments();
      _reconnectWebSocket();
      // Full server reconciliation on foreground — catches any count drift
      // that occurred while backgrounded (e.g. background FCM stopped the
      // service but main isolate _currentlyPlaying was not reset, or a stop
      // FCM was missed entirely). Runs in parallel, non-blocking.
      Future.wait([
        AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true),
        AlertReloadCoordinator.instance.reloadFood(silentReconcile: true),
        AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true),
      ]).catchError((e) {
        print('MainNavigation foreground reconciliation error: $e');
        return <void>[];
      });
    }
  }

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

    await _loadDepartments();
  }

  Future<void> _reconnectWebSocket() async {
    final userId       = await UserSessionHelper.getUserId();
    final enterpriseId = await UserSessionHelper.getEnterpriseId();
    if (userId == null || enterpriseId == null) return;
    WebSocketService().connect(
      userId:       userId.toString(),
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
        final entries = _activeEntries;
        if (_currentIndex >= entries.length) _currentIndex = 0;
      });
    }
  }

  Future<void> _requestPermissions() async {
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    await NotificationPermissionManager.requestAllPermissions(context);
  }

  // ── Role / dept changed ───────────────────────────────────────────────────

  bool _isShowingRoleChangedSheet = false;

  void _onRoleChanged() {
    if (!mounted || _isShowingRoleChangedSheet) return;
    _isShowingRoleChangedSheet = true;

    final reason = SessionChangeService.instance.changeReason;

    showModalBottomSheet(
      context: context,
      isDismissible:   false,
      enableDrag:      false,
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
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 24),
              width:  36,
              height: 4,
              decoration: BoxDecoration(
                color:        AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
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
            const Text('Account Updated', style: AppTypography.title),
            const SizedBox(height: 10),
            Text(
              reason,
              textAlign: TextAlign.center,
              style: AppTypography.bodySecondary.copyWith(height: 1.5),
            ),
            const SizedBox(height: 6),
            const Text(
              'Please log in again to continue with your updated access.',
              textAlign: TextAlign.center,
              style: AppTypography.bodySecondary,
            ),
            const SizedBox(height: 28),
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
