import 'package:flutter/material.dart';
import '../widgets/dialog_helpers.dart';
import '../services/home_service.dart';

class TicketDetailPage extends StatefulWidget {
  final Map<String, dynamic> task;
  final VoidCallback onClose;
  final Function(Map<String, dynamic> updatedTask)? onReassign;

  const TicketDetailPage({
    super.key,
    required this.task,
    required this.onClose,
    this.onReassign,
  });

  @override
  State<TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<TicketDetailPage> {
  late Map<String, dynamic> task;

  final HomeService _homeService = HomeService();




  @override
  void initState() {
    super.initState();
    task = Map<String, dynamic>.from(widget.task);
  }

  // ---------------- Time Formatting -------------------

  DateTime _parseTimestamp(String ts) {
    try {
      return DateTime.parse(ts);
    } catch (e) {
      return DateTime.now();
    }
  }

  String formatTimeAgo(String ts) {
    if (ts.isEmpty) return "";

    final createdAt = _parseTimestamp(ts);
    final now = DateTime.now();
    final diff = now.difference(createdAt);

    String timeAgo;
    if (diff.inSeconds < 60) {
      timeAgo = "${diff.inSeconds}s ago";
    } else if (diff.inMinutes < 60) {
      timeAgo = "${diff.inMinutes}m ago";
    } else if (diff.inHours < 24) {
      timeAgo = "${diff.inHours}h ago";
    } else {
      timeAgo = "${diff.inDays}d ago";
    }

    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final createdDate = DateTime(createdAt.year, createdAt.month, createdAt.day);

    String dateStr;
    if (createdDate == today) {
      dateStr =
      "Today ${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}";
    } else if (createdDate == yesterday) {
      dateStr =
      "Yesterday ${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}";
    } else {
      dateStr =
      "${createdAt.day.toString().padLeft(2, '0')}-${createdAt.month.toString().padLeft(2, '0')}-${createdAt.year} ${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}";
    }

    return "$timeAgo • $dateStr";
  }

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
              _pill(
                task["status"],
                task["statusColor"].withOpacity(0.15),
                textColor: task["statusColor"],
              ),
            ],
          ),

          const SizedBox(height: 20),

          Text(task["title"],
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),

          const SizedBox(height: 10),

          Row(
            children: [
              const Icon(Icons.access_time, color: Colors.grey, size: 18),
              const SizedBox(width: 6),
              Text(
                formatTimeAgo(task["raw"]["created_at"] ?? task["created_at"] ?? ""),
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---------------- Guest Info ----------------
          _guestSection(task["guest"] ?? "-"),

          const SizedBox(height: 16),

          // ---------------- Assigned To ----------------
          _assignedSection(task["assignedTo"] ?? "-"),

          const SizedBox(height: 25),

          if ((task["status"] ?? "").toString().toLowerCase() != "open")
            _actionButtons(context),

          const SizedBox(height: 16),

          _notesSection(task["note"] ?? task["raw"]["note_text"]),
        ],
      ),
    );
  }

  // ---------------- UI HELPERS -------------------

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

  // ---------------- Guest Section ----------------

  Widget _guestSection(String name) {
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
                    style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
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
                    style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _notesSection(String? note) {
    if (note == null || note.isEmpty) return const SizedBox();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withOpacity(0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.note_alt_outlined, color: Colors.blue, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Note",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  note,
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- Action Buttons -------------------

  Widget _actionButtons(BuildContext context) {
  final status =
      (task["status"] ?? "").toString().toLowerCase();

  final isClosed = status == "closed";

  // 🔒 CLOSED STATE
  if (isClosed) {
    return ElevatedButton.icon(
      onPressed: null,
      icon: const Icon(Icons.lock_outline),
      label: const Text("Ticket Closed"),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.grey.shade400,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 50),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  // ✅ IN PROGRESS (or anything except open/closed)
  return Column(
    children: [
      Row(
        children: [
          Expanded(
            child: ElevatedButton(
              onPressed: () => _addNotes(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text("Add Notes"),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: () => _reassign(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text("Reassign"),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      ElevatedButton.icon(
        onPressed: () async {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) =>
                const Center(child: CircularProgressIndicator()),
          );

          final result = await HomeService().closeServiceRequest(
            serviceRequestId: task["raw"]["service_request_id"],
          );

          Navigator.pop(context);

          if (!result["success"]) {
            return; // silently fail
          }

          setState(() {
            task["status"] = "Closed";
            task["statusColor"] = Colors.green;
          });

          showCustomSnackBar(context, "Ticket closed successfully!");
          widget.onClose();
        },
        icon: const Icon(Icons.check_circle_outline),
        label: const Text("Close Ticket"),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    ],
  );
}

  // ---------------- FUNCTIONS -------------------

  void _addNotes(BuildContext context) async {
    final text = await showAddNotesPopup(context);
    if (text == null || text.isEmpty) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final result = await HomeService().addNote(
      serviceRequestId: task["raw"]["service_request_id"],
      noteText: text,
    );

    Navigator.pop(context);

    if (!result["success"]) {
      return;
    }
    showCustomSnackBar(context, "Note added successfully!");
  }

  void _reassign(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final staffResult = await HomeService().getStaffList();
    Navigator.pop(context);

    if (!staffResult["success"]) {
      showCustomSnackBar(
        context,
        "Failed to load staff",
        isError: true,
      );
      return;
    }

    final List<Map<String, dynamic>> staffList =
    List<Map<String, dynamic>>.from(staffResult["staff"]);

    await showReassignPopup(
      context,
      staffList,
      onSelect: (staff) async {
        Navigator.pop(context);

        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator()),
        );

        final apiResult = await HomeService().reassignTicket(
          ticketId: task["raw"]["service_request_id"],
          assignedUserId: staff["userId"],
        );

        Navigator.pop(context);

        if (!apiResult["success"]) {
          showCustomSnackBar(
            context,
            "Reassign failed",
            isError: true,
          );
          return;
        }

        setState(() {
          task["assignedTo"] = apiResult["updatedTask"]["assigned_to_name"] ?? "-";
        });

        showCustomSnackBar(context, "Reassigned to ${staff["name"]}");

        if (widget.onReassign != null) {
          widget.onReassign!(apiResult["updatedTask"]);
        }
      },
    );
  }
}
