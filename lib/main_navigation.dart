import 'package:flutter/material.dart';
import 'home_page.dart';
import 'tasks_page.dart';
import 'profile_page.dart';

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    HomePage(),
    TasksPage(),
    ProfilePage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],

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
          backgroundColor: Colors.white,
          elevation: 0,
          type: BottomNavigationBarType.fixed,

          selectedFontSize: 12,
          unselectedFontSize: 12,

          selectedItemColor: const Color(0xFFFFC107), // yellow highlight
          unselectedItemColor: Colors.grey.shade600,

          onTap: (index) {
            setState(() => _currentIndex = index);
          },

          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined, size: 26),
              activeIcon: Icon(Icons.home, size: 26),
              label: "Home",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.folder_copy_outlined, size: 26),
              activeIcon: Icon(Icons.folder_copy, size: 26),
              label: "My Tasks",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline, size: 26),
              activeIcon: Icon(Icons.person, size: 26),
              label: "Profile",
            ),
          ],
        ),
      ),
    );
  }
}
