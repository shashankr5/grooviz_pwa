import 'package:flutter/material.dart';
import '../widgets/dialog_helpers.dart';
import '../services/home_service.dart';

class TicketDetailPage extends StatefulWidget {
  final Map<String, dynamic> task;
  final VoidCallback onClose;
  final List<Map<String, String>> staffList;
  final Function(Map<String, dynamic> updatedTask)? onReassign;

  const TicketDetailPage({
    super.key,
    required this.task,
    required this.onClose,
    required this.staffList,
    this.onReassign,
  });

  @override
  State<TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<TicketDetailPage> {
  late Map<String, dynamic> task;

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

          _actionButtons(context),
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

  // ---------------- Action Buttons -------------------

  Widget _actionButtons(BuildContext context) {
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
                      borderRadius: BorderRadius.circular(10)),
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
                      borderRadius: BorderRadius.circular(10)),
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
              builder: (_) => const Center(child: CircularProgressIndicator()),
            );

            final result = await HomeService().closeServiceRequest(
              serviceRequestId: task["raw"]["service_request_id"],
            );

            Navigator.pop(context);

            if (!result["success"]) {
              showCustomSnackBar(context, result["message"]);
              return;
            }

            setState(() {
              task["status"] = "Closed";
              task["statusColor"] = Colors.green;
            });

            showCustomSnackBar(context, "Ticket closed successfully!");
            widget.onClose();
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
      showCustomSnackBar(context, result["message"]);
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
      showCustomSnackBar(context, staffResult["message"]);
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
          showCustomSnackBar(context, apiResult["message"]);
          return;
        }

        setState(() {
          task["assignedTo"] = staff["name"];
        });

        showCustomSnackBar(context, "Reassigned to ${staff["name"]}");

        if (widget.onReassign != null) {
          widget.onReassign!(apiResult["updatedTask"]);
        }
      },
    );
  }
}

// ---------------- CLEAN POPUPS -------------------

Future<String?> showAddNotesPopup(BuildContext context) {
  final controller = TextEditingController();

  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Add Notes",
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black)),
            const SizedBox(height: 16),

            TextField(
              controller: controller,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: "Enter note",
                border: OutlineInputBorder(
                  borderSide: const BorderSide(color: Colors.black54),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.black),
                    ),
                    child: const Text("Cancel",
                        style: TextStyle(color: Colors.black)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, controller.text),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text("Add"),
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    ),
  );
}

// ---------------- REASSIGN POPUP -------------------

Future<void> showReassignPopup(
  BuildContext context,
  List<Map<String, dynamic>> staffList, {
  required Function(Map<String, dynamic>) onSelect,
}) {
  return showDialog(
    context: context,
    barrierDismissible: true,
    builder: (_) => Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Reassign",
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black)),
            const SizedBox(height: 14),

            SizedBox(
              height: 260,
              child: ListView.separated(
                itemCount: staffList.length,
                separatorBuilder: (_, __) => Container(
                  color: Colors.grey.shade300,
                  height: 1,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                ),
                itemBuilder: (_, i) {
                  final staff = staffList[i];
                  return InkWell(
                    onTap: () => onSelect(staff),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.person_outline,
                              color: Colors.black),
                          const SizedBox(width: 12),

                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  staff["name"],
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  staff["department_name"] ?? "No department",
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade700),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
