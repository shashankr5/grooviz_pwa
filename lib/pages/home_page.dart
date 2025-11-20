import 'package:flutter/material.dart';
import '../services/home_service.dart';
import 'ticket_details_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String selectedFilter = "All";

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
    _loadTasks();
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
      tasks = List<Map<String, dynamic>>.from(result["tasks"]);
      _isLoading = false;
    });
  }

  List<Map<String, dynamic>> get filteredTasks {
    if (selectedFilter == "All") return tasks;
    return tasks.where((t) => t["status"] == selectedFilter).toList();
  }

  List<Map<String, dynamic>> get activeTasks {
    return tasks.where((t) => t["status"] != "Closed").toList();
  }

  // --------------------------------------------------------------------------
  // MAIN UI
  // --------------------------------------------------------------------------
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
        children: const [
          Text("Welcome,", style: TextStyle(fontSize: 14, color: Colors.black54)),
          Text("Shashank 👋",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.notifications_outlined, size: 28),
          onPressed: () {},
        ),
        const Padding(
          padding: EdgeInsets.only(right: 12),
          child: CircleAvatar(
            backgroundColor: Colors.deepPurple,
            child: Text("S", style: TextStyle(color: Colors.white)),
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

  // --------------------------------------------------------------------------
  // TASK CARD
  // --------------------------------------------------------------------------
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
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // top row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _pill("Room ${task["room"]}", Colors.amber.shade100),
              _pill(task["status"], task["statusColor"].withOpacity(0.2),
                  textColor: task["statusColor"]),
            ],
          ),

          const SizedBox(height: 10),

          Text(task["title"],
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),

          const SizedBox(height: 5),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                const Icon(Icons.access_time, size: 18, color: Colors.grey),
                const SizedBox(width: 6),
                Text("High Priority",
                    style: TextStyle(color: Colors.grey[700], fontSize: 14)),
              ]),
              Text(task["time"],
                  style: TextStyle(color: Colors.grey[600], fontSize: 13)),
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



/*
////////////////////////////////////////////////////////////////////////////////////
//                        TICKET DETAIL PAGE (same file)
////////////////////////////////////////////////////////////////////////////////////

class TicketDetailPage extends StatelessWidget {
  final Map<String, dynamic> task;
  final VoidCallback onClose;
  final List<Map<String, String>> staffList;

  const TicketDetailPage({
    super.key,
    required this.task,
    required this.onClose,
    required this.staffList,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfffaf8f5),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        leading: BackButton(color: Colors.black),
        title: const Text("Back to Tasks",
            style: TextStyle(color: Colors.black, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _pill("Room ${task["room"]}", Colors.amber.shade100),
              _pill(task["status"], task["statusColor"].withOpacity(0.15),
                  textColor: task["statusColor"]),
            ],
          ),

          const SizedBox(height: 20),
          Text(task["title"],
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),

          const SizedBox(height: 10),

          Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 18),
              const SizedBox(width: 6),
              Text("High Priority • ${task["time"]}",
                  style: const TextStyle(fontSize: 14)),
            ],
          ),

          const SizedBox(height: 20),

          _section("Issue Description", task["description"] ?? "—"),

          const SizedBox(height: 16),

          _guestSection(task["guest"] ?? "-", task["guestNote"] ?? "-"),

          const SizedBox(height: 16),

          _assignedSection(task["assignedTo"] ?? "-"),

          const SizedBox(height: 25),

          _actionButtons(context),
        ],
      ),
    );
  }

  Widget _pill(String text, Color bg, {Color textColor = Colors.black87}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style: TextStyle(
              color: textColor, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }

  Widget _section(String title, String content) {
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(content, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  Widget _guestSection(String name, String note) {
    return _card(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.person_outlined, color: Colors.amber, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Guest Information",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(name,
                    style:
                        const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('"$note"',
                      style:
                          const TextStyle(fontSize: 14, color: Colors.black87)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _assignedSection(String name) {
    return _card(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.assignment_ind_outlined,
              color: Colors.amber, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Assigned To",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(name,
                    style:
                        const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButtons(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _addNotes(context),
                icon: const Icon(Icons.note_alt_outlined, color: Colors.black),
                label: const Text("Add Notes"),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Colors.black),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _reassign(context),
                icon: const Icon(Icons.person_outline, color: Colors.black),
                label: const Text("Reassign"),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Colors.black),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        ElevatedButton.icon(
          onPressed: () {
            onClose();
            Navigator.pop(context);
          },
          icon: const Icon(Icons.check_circle_outline),
          label: const Text("Close Ticket"),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 50),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  Widget _card(Widget child) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  void _addNotes(BuildContext context) async {
    final text = await showAddNotesPopup(context);
    if (text != null && text.isNotEmpty) {
      showCustomSnackBar(context, "Notes saved successfully!");
    }
  }

  void _reassign(BuildContext context) async {
    await showReassignPopup(context, staffList);
  }
}

////////////////////////////////////////////////////////////////////////////////
// POPUPS
////////////////////////////////////////////////////////////////////////////////

Future<String?> showAddNotesPopup(BuildContext context) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Add Notes",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: "Enter your notes...",
                filled: true,
                fillColor: Colors.grey.shade100,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
              child: const Text("Save Notes"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            )
          ],
        ),
      ),
    ),
  );
}

Future<void> showReassignPopup(
    BuildContext context, List<Map<String, String>> staffList) async {
  await showDialog(
    context: context,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Reassign Staff",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            ...staffList.map((staff) => ListTile(
                  leading:
                      const Icon(Icons.person_outline, color: Colors.black87),
                  title: Text(staff["name"]!),
                  subtitle: Text(staff["department"]!),
                  onTap: () {
                    Navigator.pop(context);
                    showCustomSnackBar(
                        context, "Ticket reassigned to ${staff["name"]}");
                  },
                )),
          ],
        ),
      ),
    ),
  );
}

////////////////////////////////////////////////////////////////////////////////
// CUSTOM SNACKBAR
////////////////////////////////////////////////////////////////////////////////

void showCustomSnackBar(BuildContext context, String message) {
  final overlay = Overlay.of(context);
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      bottom: 20,
      left: 20,
      right: 20,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black12.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: Colors.black),
              const SizedBox(width: 12),
              Expanded(
                child: Text(message,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  overlay.insert(entry);
  Future.delayed(const Duration(seconds: 2), entry.remove);
}

*/
