import 'package:flutter/material.dart';
import 'home_page.dart';
import 'tasks_page.dart';
import 'profile_page.dart';
import 'food_orders_page.dart';
import 'camera_content_page.dart';
import '../utils/notification_permission_manager.dart';

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  /// Order of pages MUST match BottomNavigationBar items exactly
  final List<Widget> _pages = [
    const HomePage(key: PageStorageKey('home')),
    const FoodOrdersPage(key: PageStorageKey('food')),
    const TasksPage(key: PageStorageKey('tasks')),
    const CameraContentPage(key: PageStorageKey('camera')),
  ];

  @override
  void initState() {
    super.initState();

    // Request permission AFTER user enters app
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await Future.delayed(const Duration(milliseconds: 500)); 
    // small delay = smoother UX

    await NotificationPermissionManager.requestAllNotificationPermissions();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          backgroundColor: Colors.transparent,
          elevation: 0,
          type: BottomNavigationBarType.fixed, // Required for 5 items
          selectedFontSize: 12,
          unselectedFontSize: 12,
          selectedItemColor: const Color(0xFFFFC107),
          unselectedItemColor: Colors.grey.shade600,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined, size: 26),
              activeIcon: Icon(Icons.home, size: 26),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.fastfood_outlined, size: 26),
              activeIcon: Icon(Icons.fastfood, size: 26),
              label: 'Food',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.task_alt_outlined, size: 26),
              activeIcon: Icon(Icons.task_alt, size: 26),
              label: 'My Tasks',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.camera_alt_outlined, size: 26),
              activeIcon: Icon(Icons.camera_alt, size: 26),
              label: 'Camera',
            ),
          ],
        ),
      ),
    );
  }
}