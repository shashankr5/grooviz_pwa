import 'package:flutter/material.dart';
import '../services/task_service.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  final TaskService _taskService = TaskService();

  bool _isLoading = true;
  List<dynamic> _recentTasks = [];

  int totalTasks = 0;
  int completedTasks = 0;
  int inProgressTasks = 0;

  @override
  void initState() {
    super.initState();
    _loadTasks();
  }

  Future<void> _loadTasks() async {
    final res = await _taskService.fetchTaskSummary();

    if (!mounted) return;

    if (res["success"]) {
      List<dynamic> tasks = res["tasks"];

      setState(() {
        _recentTasks = tasks;

        totalTasks = tasks.length;

        // ✅ Count both Completed and Closed as completed today
        completedTasks = tasks
            .where((t) => t["status"] == "Completed" || t["status"] == "Closed")
            .length;

        inProgressTasks =
            tasks.where((t) => t["status"] == "In Progress").length;

        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(res["message"] ?? "Error")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "My Tasks",
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      "Your performance overview",
                      style: TextStyle(fontSize: 15, color: Colors.grey),
                    ),
                    const SizedBox(height: 20),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildStatBox(
                          icon: Icons.access_time,
                          count: "$totalTasks",
                          label: "Total Tasks",
                          iconColor: Colors.amber.shade600,
                        ),
                        _buildStatBox(
                          icon: Icons.check_circle,
                          count: "$completedTasks",
                          label: "Completed Today",
                          iconColor: Colors.green.shade600,
                        ),
                        _buildStatBox(
                          icon: Icons.timelapse_outlined,
                          count: "$inProgressTasks",
                          label: "In Progress",
                          iconColor: Colors.orange.shade600,
                        ),
                      ],
                    ),

                    const SizedBox(height: 28),

                    const Text(
                      "Recent Activity",
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 16),

                    if (_recentTasks.isEmpty)
                      const Text("No recent tasks found",
                          style: TextStyle(color: Colors.grey))
                    else
                      ..._recentTasks.map((task) {
                        String status = task["status"] ?? "";
                        Color statusColor = (status == "Completed" || status == "Closed")
                            ? Colors.green
                            : Colors.orange;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildActivityCard(
                            room: task["roomNumber"] ?? "-",
                            title: task["question"] ?? "",
                            time: task["timeAgo"] ?? "",
                            status: status,
                            statusColor: statusColor,
                          ),
                        );
                      }),
                  ],
                ),
              ),
      ),
    );
  }

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
          Text(count,
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800)),
        ],
      ),
    );
  }

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
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(room,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade800)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(status,
                    style: TextStyle(
                        color: statusColor, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(title,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(time,
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
        ],
      ),
    );
  }
}
