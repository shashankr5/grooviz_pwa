// home_page.dart — cleaned and separated version

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'ticket_details_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String selectedFilter = "All";
  List<Map<String, dynamic>> tasks = [];
  List<Map<String, String>> staffList = [];

  bool isLoading = true;
  int newTaskCount = 0;
  String userName = "User";
  Color userAvatarColor = Colors.deepPurple; // constant random color

  @override
  void initState() {
    super.initState();
    _generateAvatarColor();
    fetchData();
  }

  void _generateAvatarColor() {
    final List<Color> colors = [
      Colors.deepPurple,
      Colors.blue,
      Colors.green,
      Colors.teal,
      Colors.orange,
      Colors.indigo,
    ];
    userAvatarColor = colors[DateTime.now().millisecondsSinceEpoch % colors.length];
  }

  Future<void> fetchData() async {
    await Future.wait([fetchTasks(), fetchStaff()]);
    setState(() => isLoading = false);
  }

  Future<void> fetchTasks() async {
    try {
      final response = await http.get(Uri.parse(
        "https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production/ScreenSync_get_tasks_mobile",
      ));

      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        setState(() {
          tasks = data.map((task) => Map<String, dynamic>.from(task)).toList();
          updateNewTaskCount();
        });
      }
    } catch (e) {
      debugPrint("Error fetching tasks: $e");
    }
  }

  Future<void> fetchStaff() async {
    try {
      final response = await http.get(Uri.parse(
        "https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production/ScreenSync_get_staff_list_mobile",
      ));

      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        setState(() {
          staffList = data.map((staff) => Map<String, String>.from(staff)).toList();
          if (staffList.isNotEmpty) userName = staffList[0]["name"] ?? "User";
        });
      }
    } catch (e) {
      debugPrint("Error fetching staff: $e");
    }
  }

  void updateNewTaskCount() {
    newTaskCount = tasks.where((t) => (t["status"] ?? "") == "Open").length;
  }

  List<Map<String, dynamic>> get filteredTasks {
    if (selectedFilter == "All") return tasks;
    return tasks.where((t) => (t["status"] ?? "") == selectedFilter).toList();
  }

  List<Map<String, dynamic>> get activeTasks {
    return tasks.where((t) => (t["status"] ?? "") != "Closed").toList();
  }

  String? _getAssigned(Map<String, dynamic> task) {
    if (task["assigned_to"] != null && task["assigned_to"].toString().isNotEmpty) {
      return task["assigned_to"].toString();
    }

    if (task["assignedTo"] != null && task["assignedTo"].toString().isNotEmpty) {
      return task["assignedTo"].toString();
    }

    return null;
  }

  void _setAssigned(Map<String, dynamic> task, dynamic value) {
    task["assigned_to"] = value;
    task["assignedTo"] = value;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: _buildAppBar(),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 15),
                _buildFilterTabs(),
                const SizedBox(height: 20),
                _buildTaskHeader(),
                const SizedBox(height: 15),
                Expanded(child: _buildTaskList()),
              ],
            ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
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
        Stack(
          children: [
            IconButton(
              icon: const Icon(Icons.notifications_outlined, size: 28),
              onPressed: () {},
            ),
            if (newTaskCount > 0)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: CircleAvatar(
            backgroundColor: userAvatarColor,
            child: Text(
              userName.isNotEmpty ? userName[0].toUpperCase() : "?",
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterTabs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _filterChip("All"),
          _filterChip("Open"),
          _filterChip("In Progress"),
          _filterChip("Closed"),
        ],
      ),
    );
  }

  Widget _filterChip(String label) {
    final selected = selectedFilter == label;
    return GestureDetector(
      onTap: () => setState(() => selectedFilter = label),
      child: Container(
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.amber[700] : Colors.white,
          borderRadius: BorderRadius.circular(25),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: selected ? Colors.white : Colors.black87,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildTaskHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Tasks", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text(
            "${activeTasks.length} active tickets",
            style: TextStyle(fontSize: 14, color: Colors.grey[700]),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList() {
    return ListView.builder(
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
                      task["status"] = "Closed";
                      updateNewTaskCount();
                    });
                  },
                ),
              ),
            );
            setState(() {});
          },
          child: _taskCard(task),
        );
      },
    );
  }

  Widget _taskCard(Map<String, dynamic> task) {
    final assigned = _getAssigned(task);
    final isAssigned = assigned != null;
    final status = (task["status"] ?? "").toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black12.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _pill("Room ${task["room"]}", Colors.amber.shade100),
              _pill(status, Colors.blue.withOpacity(0.15)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            task["title"] ?? "",
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 5),
          Text(
            task["subtitle"] ?? "",
            style: TextStyle(color: Colors.grey[700]),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  "Assigned To: ${assigned ?? "Not Assigned"}",
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (!isAssigned)
                _AcceptButton(
                  taskId: task["service_request_id"] ?? task["id"],
                  onAccepted: (userId) {
                    setState(() {
                      _setAssigned(task, userId);
                      task["status"] = "In Progress";
                      updateNewTaskCount();
                    });
                  },
                )
              else
                Text(
                  task["time"] ?? "",
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
  
  TicketDetailPage({required Map<String, dynamic> task, required List<Map<String, String>> staffList, required Null Function() onClose}) {}
}

class _AcceptButton extends StatefulWidget {
  final dynamic taskId;
  final void Function(String assignedId) onAccepted;

  const _AcceptButton({required this.taskId, required this.onAccepted});

  @override
  State<_AcceptButton> createState() => _AcceptButtonState();
}

class _AcceptButtonState extends State<_AcceptButton> {
  bool loading = false;

  Future<void> _acceptTask(int taskId) async {
    setState(() => loading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt("user_id")?.toString() ?? "0";

      final url = Uri.parse(
        "https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production/ScreenSync_task_accept_mobile",
      );

      final body = {
        "json_input": {
          "user_id": userId,
          "service_request_id": taskId,
          "assigned_to": userId,
          "status": "In Progress"
        }
      };

      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        widget.onAccepted(userId);
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: loading
          ? const SizedBox(
              width: 90,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : ElevatedButton(
              onPressed: () {
                final id = int.tryParse(widget.taskId.toString());
                if (id != null) _acceptTask(id);
              },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text("ACCEPT"),
            ),
    );
  }
}