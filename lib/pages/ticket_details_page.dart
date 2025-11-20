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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfffaf8f5),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        leading: BackButton(color: Colors.black),
        title: const Text(
          "Back to Tasks",
          style: TextStyle(color: Colors.black, fontSize: 18),
        ),
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

          Text(
            task["title"],
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 10),

          Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 18),
              const SizedBox(width: 6),
              Text(
                "High Priority • ${task["time"]}",
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),

          const SizedBox(height: 20),

          _section("Issue Description", task["description"] ?? "—"),

          const SizedBox(height: 16),

          _guestSection(task["guest"] ?? "-", ""),

          const SizedBox(height: 16),

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
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
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
                const Text(
                    "Guest Information",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                    name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),

                /// ❗ REMOVE phone number display – keep blank container
                Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                    "",
                    style: TextStyle(fontSize: 14, color: Colors.black87),
                    ),
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
            onPressed: () async {
                showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Center(child: CircularProgressIndicator()),
                );

                final result = await HomeService().closeServiceRequest(
                serviceRequestId: task["raw"]["service_request_id"],
                );

                Navigator.pop(context); // close loader

                if (!result["success"]) {
                showCustomSnackBar(context, result["message"]);
                return;
                }

                // Update UI locally
                setState(() {
                task["status"] = "Closed";
                task["statusColor"] = Colors.green;
                });

                showCustomSnackBar(context, "Ticket closed successfully!");

                widget.onClose(); // notify homepage
                Navigator.pop(context); // close detail page
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

        // Show loader
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

        // Update UI
        setState(() {
          task["assignedTo"] = staff["name"];
        });

        showCustomSnackBar(context, "Reassigned to ${staff["name"]}");

        // notify homepage
        if (widget.onReassign != null) {
          widget.onReassign!(apiResult["updatedTask"]);
        }
      },
    );
  }
}
