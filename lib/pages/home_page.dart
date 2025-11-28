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


  Future<void> _loadUserName() async {
    final name = await UserSessionHelper.getUserName();
    if (mounted) {
      setState(() {
        userName = name ?? "User";
      });
    }
  }

  // --------------------------------------------------------------------------
  // LOAD TASKS FROM API
  // --------------------------------------------------------------------------
  Future<void> _loadTasks() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await HomeService().getTasks();

    if (!mounted) return;

    if (!result["success"]) {
      setState(() {
        _errorMessage = result["message"];
        _isLoading = false;
      });
      return;
    }

    setState(() {
      tasks = List<Map<String, dynamic>>.from(result["tasks"]).map((t) {
        return {
          ...t,
          "isAccepted": t["status"] == "In Progress",   // already accepted earlier
          "statusColor": getStatusColor(t["status"]),
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

    await _loadTasks();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Task Accepted 🎉")),
    );
  }



  List<Map<String, dynamic>> get filteredTasks {
    if (selectedFilter == "All") return tasks;
    return tasks.where((t) => t["status"] == selectedFilter).toList();
  }

  List<Map<String, dynamic>> get activeTasks {
    return tasks.where((t) => t["status"] != "Closed").toList();
  }


  // MAIN UI

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
          padding: EdgeInsets.only(right: 12),
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

  // MAIN CONTENT

  Widget _buildContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 15),
        _buildFilters(),
        const SizedBox(height: 20),

        // HEADER
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Tasks",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text("${activeTasks.length} active tickets",
                  style: TextStyle(fontSize: 14, color: Colors.grey[700])),
            ],
          ),
        ),

        const SizedBox(height: 15),

        Expanded(
          child: ListView.builder(
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
                            task["statusColor"] = Colors.green;
                          });
                        },
                        onReassign: (updatedTask) async {
                          // Refresh home page tasks completely
                          await _loadTasks();
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
      ],
    );
  }

  // --------------------------------------------------------------------------
  // FILTER TABS
  // --------------------------------------------------------------------------
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


  // TASK CARD
  
  Widget _buildTaskCard(Map<String, dynamic> task) {
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
          // Top Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _pill("Room ${task["room"]}", Colors.amber.shade100),
              _pill(task["status"], task["statusColor"].withOpacity(0.2),
                  textColor: task["statusColor"]),
            ],
          ),

          const SizedBox(height: 12),

          // TITLE ONLY
          Text(
            task["title"],
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 18),

          // Buttons Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              (task["status"] == "Open")
                ? ElevatedButton(
                    onPressed: () => _acceptTask(task),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    child: const Text("Accept"),
                  )
                : Row(
                    children: const [
                      Icon(Icons.check_circle, size: 18, color: Colors.green),
                      SizedBox(width: 6),
                      Text(
                        "Accepted",
                        style: TextStyle(color: Colors.green, fontSize: 14),
                      ),
                    ],
                  ),
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




  Widget _pill(String text, Color bg, {Color textColor = Colors.black87}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style: TextStyle(
              color: textColor, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }
}