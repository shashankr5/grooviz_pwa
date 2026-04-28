import 'package:flutter/material.dart';
import '../services/task_service.dart';
import '../utils/app_colors.dart';

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
      setState(() {
        _recentTasks = res["tasks"] ?? [];
        totalTasks = res["totalTasks"] ?? 0;
        completedTasks = res["completedToday"] ?? 0;
        inProgressTasks = res["inProgressTasks"] ?? 0;
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
      backgroundColor: AppColors.bgLight,
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "My Tasks",
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 22,
              ),
            ),
            Text(
              "Your performance overview",
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
        elevation: 0,
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadTasks,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStatCards(),
                    _buildRecentActivity(),
                    _buildMotivationBanner(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Stat cards – content decides height, no overflow
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildStatCards() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: _buildStatCard(
              count: "$totalTasks",
              label: "Total Tasks",
              icon: Icons.assignment_outlined,
              iconBg: AppColors.primary.withOpacity(0.1),
              iconColor: AppColors.primary,
              accentColor: AppColors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard(
              count: "$completedTasks",
              label: "Completed Today",
              icon: Icons.check_circle_outline,
              iconBg: const Color(0xFFE8F5E9),
              iconColor: const Color(0xFF2E7D32),
              accentColor: const Color(0xFF2E7D32),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard(
              count: "$inProgressTasks",
              label: "In Progress",
              icon: Icons.timelapse_outlined,
              iconBg: const Color(0xFFF0F1FF),
              iconColor: AppColors.primary,
              accentColor: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required String count,
    required String label,
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required Color accentColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconBg,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(height: 8),
          Text(
            count,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: accentColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Recent Activity section
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildRecentActivity() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Recent Activity",
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),              
              //TextButton(
              //  onPressed: () {},
              //  child: const Text(
              //    "View all",
              //    style: TextStyle(
              //        color: AppColors.primary, fontWeight: FontWeight.w600),
              //  ),
              //),
            ],
          ),
          const SizedBox(height: 8),
          if (_recentTasks.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  Icon(Icons.task_alt,
                      size: 40, color: AppColors.textSecondary),
                  const SizedBox(height: 8),
                  const Text("No recent tasks found",
                      style: TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _recentTasks.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: AppColors.textSecondary,
                  indent: 16,
                  endIndent: 16,
                ),
                itemBuilder: (context, index) {
                  final task = _recentTasks[index];
                  final status = task["status"] ?? "";

                  Color statusColor;
                  Color statusBg;
                  switch (status) {
                    case "Closed":
                      statusColor = AppColors.secondary;
                      statusBg = AppColors.secondary.withOpacity(0.1);
                      break;

                    case "In Progress":
                      statusColor = Colors.orange;
                      statusBg = Colors.orange.withOpacity(0.1);
                      break;

                    default:
                      statusColor = AppColors.primary;
                      statusBg = AppColors.primary.withOpacity(0.1);
                  }

                  return _buildActivityTile(
                    room: task["roomNumber"] ?? "-",
                    title: task["question"] ?? "",
                    time: task["timeAgo"] ?? "",
                    status: status,
                    statusColor: statusColor,
                    statusBg: statusBg,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActivityTile({
    required String room,
    required String title,
    required String time,
    required String status,
    required Color statusColor,
    required Color statusBg,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Text(
              room,
              style: const TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  time,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusBg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status,
              style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Motivation banner (unchanged)
  // ──────────────────────────────────────────────────────────────────────────
  Widget _buildMotivationBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.primary.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.star_outline,
                  color: AppColors.primary, size: 26),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Great work!",
                    style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 15),
                  ),
                  SizedBox(height: 2),
                  Text(
                    "Keep up the good work and complete more tasks.",
                    style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.checklist_rtl_outlined,
                color: AppColors.primary.withOpacity(0.4), size: 40),
          ],
        ),
      ),
    );
  }
}