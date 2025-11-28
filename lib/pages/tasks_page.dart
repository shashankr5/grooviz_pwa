import 'package:flutter/material.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  // -----------------------
  // Sample dynamic tasks list
  // Replace this with API fetch
  // -----------------------
  List<Map<String, dynamic>> tasks = [
    {
      "room": "302",
      "status": "Closed",
      "title": "Resolved leaking faucet",
      "time": "2h ago",
      "priority": "High",
    },
    {
      "room": "405",
      "status": "In Progress",
      "title": "Working on AC issue",
      "time": "30m ago",
      "priority": "High",
    },
    {
      "room": "210",
      "status": "Closed",
      "title": "Delivered extra towels",
      "time": "1h ago",
      "priority": "Low",
    },
    {
      "room": "108",
      "status": "Open",
      "title": "Broken lamp replacement",
      "time": "15m ago",
      "priority": "Medium",
    }
  ];

  // --------------------------------------------
  // NEW: recent activities = last 10 closed + in-progress
  // --------------------------------------------
  List<Map<String, dynamic>> get recentActivities {
    List<Map<String, dynamic>> list = tasks
        .where((t) => t["status"] == "Closed" || t["status"] == "In Progress")
        .toList();

    return list.take(10).toList(); // recent 10 max
  }

  @override
  Widget build(BuildContext context) {
    final totalTasks = tasks.length;
    final completedTasks =
        tasks.where((t) => t["status"] == "Closed").length;
    final highPriorityTasks =
        tasks.where((t) => t["priority"] == "High").length;

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              /// ---------------------------
              /// TITLE
              /// ---------------------------
              const Text(
                "My Tasks",
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),

              Text(
                "$totalTasks tasks in total • $completedTasks completed",
                style: TextStyle(fontSize: 15, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 20),

              /// ---------------------------
              /// 3 INFO BOXES
              /// ---------------------------
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildStatBox(
                    icon: Icons.access_time,
                    count: totalTasks.toString(),
                    label: "Total Tasks",
                    iconColor: Colors.amber.shade600,
                  ),
                  _buildStatBox(
                    icon: Icons.check_circle,
                    count: completedTasks.toString(),
                    label: "Completed",
                    iconColor: Colors.green.shade600,
                  ),
                  _buildStatBox(
                    icon: Icons.error,
                    count: highPriorityTasks.toString(),
                    label: "High Priority",
                    iconColor: Colors.red.shade600,
                  ),
                ],
              ),

              const SizedBox(height: 28),

              /// ---------------------------
              /// RECENT ACTIVITY TITLE
              /// ---------------------------
              const Text(
                "Recent Activity",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),

              /// ---------------------------
              /// ACTIVITY LIST (DYNAMIC)
              /// Shows only latest 10 of: Closed + In Progress
              /// ---------------------------
              Column(
                children: recentActivities.map((task) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _buildActivityCard(
                      room: task["room"],
                      title: task["title"],
                      time: task["time"],
                      status: task["status"],
                      statusColor: getStatusColor(task["status"]),
                    ),
                  );
                }).toList(),
              ),

              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  /// ------------------------------------
  /// BOX BUILDER (3 stats)
  /// ------------------------------------
  Widget _buildStatBox({
    required IconData icon,
    required String count,
    required String label,
    required Color iconColor,
  }) {
    return Container(
      width: 105,
      padding: const EdgeInsets.symmetric(vertical: 18),
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
          Icon(icon, size: 28, color: iconColor),
          const SizedBox(height: 8),
          Text(
            count,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: Colors.grey.shade800,
            ),
          ),
        ],
      ),
    );
  }

  /// ------------------------------------
  /// ACTIVITY CARD BUILDER
  /// ------------------------------------
  Widget _buildActivityCard({
    required String room,
    required String title,
    required String time,
    required String status,
    required Color statusColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 5,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              /// ROOM TAG
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  room,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.orange.shade800,
                  ),
                ),
              ),

              /// STATUS TAG
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: 6),

          Text(
            time,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  /// ------------------------------------
  /// Helper to get color based on status
  /// ------------------------------------
  Color getStatusColor(String status) {
    switch (status) {
      case "Closed":
        return Colors.green;
      case "In Progress":
        return Colors.orange;
      case "Open":
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}
