import 'package:flutter/material.dart';
import '../services/home_service.dart';
import 'ticket_details_page.dart';
import '../utils/user_session_helper.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String selectedFilter = "All";
  String selectedDateFilter = "All Days"; 
  String userName = "";

  bool _isLoading = true;
  String? _errorMessage;

  List<Map<String, dynamic>> tasks = [];

  final List<Map<String, String>> staffList = [
    {"name": "John Doe", "department": "Maintenance"},
    {"name": "Aisha Sharma", "department": "Housekeeping"},
    {"name": "Rahul Verma", "department": "Electrical"},
    {"name": "Priya Nair", "department": "Plumbing"},
    {"name": "Rahul Raj", "department": "Security"},
    {"name": "Karun Nair", "department": "Admin"},
  ];

  @override
  void initState() {
    super.initState();
    _loadUserName();
    _loadTasks();
  }

  Color getStatusColor(String status) {
    switch (status) {
      case "Open":
        return Colors.blue;
      case "In Progress":
        return Colors.orange;
      case "Closed":
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  DateTime _parseTimestamp(String ts) {
    try {
      return DateTime.parse(ts);
    } catch (e) {
      return DateTime.now();
    }
  }

  bool isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  bool isYesterday(DateTime date) {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    return date.year == yesterday.year &&
        date.month == yesterday.month &&
        date.day == yesterday.day;
  }

  Future<void> _loadUserName() async {
    final name = await UserSessionHelper.getUserName();
    if (mounted) {
      setState(() {
        userName = name ?? "User";
      });
    }
  }

  String formatTimeAgo(String ts) {
    if (ts.isEmpty) return "";

    final createdAt = _parseTimestamp(ts);
    final now = DateTime.now();
    final diff = now.difference(createdAt);

    if (diff.inSeconds < 60) return "${diff.inSeconds}s ago";
    if (diff.inMinutes < 60) return "${diff.inMinutes}m ago";
    if (diff.inHours < 24) return "${diff.inHours}h ago";
    return "${diff.inDays}d ago";
  }

  Color getTaskPriorityColor(String createdAt) {
    final taskTime = _parseTimestamp(createdAt);
    final diff = DateTime.now().difference(taskTime);
    if (diff.inHours < 1) return Colors.green;
    if (diff.inHours >= 1 && diff.inHours < 8) return Colors.yellow;
    return Colors.red;
  }

  Future<void> _loadTasks() async {
    if (tasks.isEmpty) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    final result = await HomeService().getTasks();
    if (!mounted) return;

    if (!result["success"]) {
      setState(() {
        _errorMessage = result["message"];
        _isLoading = false;
      });
      return;
    }

    List<Map<String, dynamic>> raw =
        List<Map<String, dynamic>>.from(result["tasks"]);

    raw.sort((a, b) {
      final da = _parseTimestamp(a["raw"]["created_at"] ?? a["created_at"]);
      final db = _parseTimestamp(b["raw"]["created_at"] ?? b["created_at"]);
      return db.compareTo(da);
    });

    setState(() {
      tasks = raw.map((t) {
        String? assignedTo;
        if (t["status"] == "In Progress") {
          assignedTo = t["raw"]["assigned_to_name"] ??
              t["raw"]["assigned_user_name"] ??
              t["raw"]["assigned_name"] ??
              "-";
        }

        return {
          ...t,
          "isAccepted": t["status"] == "In Progress",
          "statusColor": getStatusColor(t["status"]),
          "assignedTo": assignedTo,
        };
      }).toList();

      _isLoading = false;
    });
  }

  Future<void> _acceptTask(Map<String, dynamic> task) async {
    final taskId = task["raw"]?["service_request_id"];
    if (taskId == null) return;

    setState(() => _isLoading = true);
    final result = await HomeService().acceptTask(taskId: taskId);
    setState(() => _isLoading = false);

    if (!result["success"]) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result["message"] ?? "Failed to accept task")),
      );
      return;
    }

    final updated = result["updatedTask"];
    if (updated != null) {
      setState(() {
        task["status"] = "In Progress";
        task["statusColor"] = Colors.orange;
        task["assignedTo"] = updated["assigned_to_name"] ?? userName;
      });
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Task Accepted 🎉")),
    );
  }

  List<Map<String, dynamic>> get filteredTasks {
    List<Map<String, dynamic>> byStatus =
        selectedFilter == "All"
            ? tasks.where((t) => t["status"] == "Open" || t["status"] == "In Progress").toList()
            : tasks.where((t) => t["status"] == selectedFilter).toList();

    return byStatus.where((t) {
      final createdAt = t["raw"]?["created_at"] ?? t["created_at"] ?? "";
      final date = _parseTimestamp(createdAt);

      switch (selectedDateFilter) {
        case "Today":
          return isToday(date);
        case "Yesterday":
          return isYesterday(date);
        case "Older":
          return !isToday(date) && !isYesterday(date);
        default:
          return true;
      }
    }).toList();
  }

  List<Map<String, dynamic>> get activeTasks {
    return tasks
        .where((t) => t["status"] == "Open" || t["status"] == "In Progress")
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: _buildAppBar(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? _buildError()
              : _buildContent(),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.white,
      elevation: 1,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Welcome,", style: TextStyle(fontSize: 14, color: Colors.black54)),
          Text(
            "$userName 👋",
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.notifications_outlined, size: 28),
          onPressed: () {},
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: CircleAvatar(
            backgroundColor: Colors.deepPurple,
            child: Text(
              userName.isNotEmpty ? userName[0].toUpperCase() : "?",
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        )
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_errorMessage ?? "Something went wrong"),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: _loadTasks,
            child: const Text("Retry"),
          )
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 15),
        _buildFilters(),
        const SizedBox(height: 25),

        // ⭐ MODIFIED — Heading + Black & White Dropdown
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Tasks",
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text("${activeTasks.length} active tickets",
                      style: TextStyle(fontSize: 14, color: Colors.grey[700])),
                ],
              ),

              // ⭐ NEW Black & White Dropdown
              Theme(
                data: Theme.of(context).copyWith(
                  canvasColor: Colors.white, // dropdown background
                  textTheme: const TextTheme(
                    bodyMedium: TextStyle(color: Colors.black),
                  ),
                ),
                child: DropdownButton<String>(
                  value: selectedDateFilter,
                  style: const TextStyle(color: Colors.black, fontSize: 14),
                  underline: const SizedBox(),
                  iconEnabledColor: Colors.black,
                  items: const [
                    DropdownMenuItem(value: "All Days", child: Text("All Days")),
                    DropdownMenuItem(value: "Today", child: Text("Today")),
                    DropdownMenuItem(value: "Yesterday", child: Text("Yesterday")),
                    DropdownMenuItem(value: "Older", child: Text("Older")),
                  ],
                  onChanged: (value) {
                    setState(() => selectedDateFilter = value!);
                  },
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadTasks,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: filteredTasks.length,
              itemBuilder: (context, index) {
                final task = filteredTasks[index];
                return GestureDetector(
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TicketDetailPage(
                          task: task,
                          staffList: staffList,
                          onClose: () {
                            setState(() {
                              final idx = tasks.indexWhere((t) =>
                                  t["raw"]["service_request_id"] ==
                                  task["raw"]["service_request_id"]);
                              if (idx != -1) {
                                tasks[idx]["status"] = "Closed";
                                tasks[idx]["statusColor"] = getStatusColor("Closed");
                                tasks[idx]["isAccepted"] = false;
                              }
                            });
                          },
                          onReassign: (updatedTask) {
                            setState(() {
                              final idx = tasks.indexWhere((t) =>
                                  t["raw"]["service_request_id"] ==
                                  updatedTask["service_request_id"]);
                              if (idx != -1) {
                                tasks[idx]["assignedTo"] =
                                    updatedTask["assigned_to_name"] ?? "-";
                                tasks[idx]["status"] =
                                    updatedTask["status"] ?? tasks[idx]["status"];
                                tasks[idx]["statusColor"] =
                                    getStatusColor(tasks[idx]["status"]);
                                tasks[idx]["isAccepted"] = true;
                              }
                            });
                          },
                        ),
                      ),
                    );

                    setState(() {});
                  },
                  child: _buildTaskCard(task),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilters() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _buildFilterChip("All"),
          _buildFilterChip("Open"),
          _buildFilterChip("In Progress"),
          _buildFilterChip("Closed"),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String text) {
    bool selected = selectedFilter == text;
    return GestureDetector(
      onTap: () => setState(() => selectedFilter = text),
      child: Container(
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.amber[700] : Colors.white,
          borderRadius: BorderRadius.circular(25),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Text(
          text,
          style: TextStyle(
              fontSize: 14,
              color: selected ? Colors.white : Colors.black87,
              fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildTaskCard(Map<String, dynamic> task) {
    final createdAt = task["raw"]["created_at"] ?? task["created_at"] ?? "";
    final stripColor = getTaskPriorityColor(createdAt);

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black12.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 160,
              decoration: BoxDecoration(
                color: stripColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _pill("Room ${task["room"]}", Colors.amber.shade100),
                        _pill(
                          task["status"],
                          task["statusColor"].withOpacity(0.2),
                          textColor: task["statusColor"],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      task["title"],
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (task["isAccepted"] == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          "Assigned: ${task["assignedTo"] ?? "-"}",
                          style:
                              const TextStyle(color: Colors.green, fontSize: 14),
                        ),
                      ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        (task["status"] == "Open")
                            ? ElevatedButton(
                                onPressed: () => _acceptTask(task),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 8),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                                child: const Text("Accept"),
                              )
                            : const SizedBox.shrink(),
                        Text(
                          formatTimeAgo(createdAt),
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String text, Color bg, {Color textColor = Colors.black87}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style:
              TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }
}
