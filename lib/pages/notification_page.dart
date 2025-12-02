import 'package:flutter/material.dart';

class NotificationPage extends StatelessWidget {
  const NotificationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: const Text(
          "Notifications",
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 20,
          ),
        ),
      ),
      backgroundColor: const Color(0xfffaf8f5),

      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text(
              "Push Notifications",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text("Receive updates and alerts"),
            value: true,
            onChanged: (v) {},
          ),

          const Divider(),

          SwitchListTile(
            title: const Text(
              "Task Updates",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text("Notify when a task is assigned or updated"),
            value: true,
            onChanged: (v) {},
          ),

          const Divider(),

          SwitchListTile(
            title: const Text(
              "Announcements",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text("Receive important announcements"),
            value: false,
            onChanged: (v) {},
          ),
        ],
      ),
    );
  }
}