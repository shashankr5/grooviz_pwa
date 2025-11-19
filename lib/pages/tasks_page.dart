import 'package:flutter/material.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
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
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),

              const Text(
                "Your performance overview",
                style: TextStyle(fontSize: 15, color: Colors.grey),
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
                    count: "12",
                    label: "Total Tasks",
                    iconColor: Colors.amber.shade600,
                  ),
                  _buildStatBox(
                    icon: Icons.check_circle,
                    count: "5",
                    label: "Completed Today",
                    iconColor: Colors.green.shade600,
                  ),
                  _buildStatBox(
                    icon: Icons.error,
                    count: "3",
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
              /// ACTIVITY LIST
              /// ---------------------------
              _buildActivityCard(
                room: "302",
                title: "Resolved leaking faucet",
                time: "2h ago",
                status: "Done",
                statusColor: Colors.green,
              ),

              const SizedBox(height: 12),

              _buildActivityCard(
                room: "405",
                title: "Working on AC issue",
                time: "30m ago",
                status: "Active",
                statusColor: Colors.orange,
              ),

              const SizedBox(height: 12),

              _buildActivityCard(
                room: "210",
                title: "Delivered extra towels",
                time: "1h ago",
                status: "Done",
                statusColor: Colors.green,
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
}
