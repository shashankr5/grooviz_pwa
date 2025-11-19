import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'pages/login_page.dart';
import 'pages/main_navigation.dart';

import 'services/fcm_service.dart';
import 'utils/user_session_helper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  await FCMService.initialize();

  // ✅ Check if user is logged in
  final bool isLoggedIn = await UserSessionHelper.isLoggedIn();

  runApp(MyApp(isLoggedIn: isLoggedIn));
}

class MyApp extends StatelessWidget {
  final bool isLoggedIn;

  const MyApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Login UI',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),

      // 👇 This decides startup screen
      home: isLoggedIn ? const MainNavigation() : const LoginPage(),
    );
  }
}
