import 'package:flutter/material.dart';

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
              onPressed: () =>
                  Navigator.pop(context, controller.text.trim()),
              style:
                  ElevatedButton.styleFrom(backgroundColor: Colors.amber),
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
BuildContext context,
List<Map<String, dynamic>> staffList, {
required Function(Map<String, dynamic>) onSelect,
}) async {
await showDialog(
    context: context,
    builder: (_) => Dialog(
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
                leading: const Icon(Icons.person_outline),
                title: Text(staff["name"]),
                subtitle: Text(staff["department"]),
                onTap: () => onSelect(staff),
                )),
        ],
        ),
    ),
    ),
);
}


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
