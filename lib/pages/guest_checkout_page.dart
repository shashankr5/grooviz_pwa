import 'package:flutter/material.dart';
import '../services/checkout_service.dart';
import '../utils/app_snackbar.dart';

class GuestCheckoutPage extends StatefulWidget {
  const GuestCheckoutPage({super.key});

  @override
  State<GuestCheckoutPage> createState() => _GuestCheckoutPageState();
}

class _GuestCheckoutPageState extends State<GuestCheckoutPage> {
  late Future<List<Map<String, dynamic>>> _futureGuests;

    DateTime? _parseDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return null;
    try {
        return DateTime.parse(dateStr).toLocal(); 
    } catch (_) {
        return null;
    }
    }

  Future<List<Map<String, dynamic>>> _loadGuests() async {
    final res = await CheckoutService().getGuestCheckoutReport();

    if (res["success"] != true) {
        throw Exception(res["message"]);
    }

    return List<Map<String, dynamic>>.from(res["guests"]);
}    

  @override
  void initState() {
    super.initState();
    _futureGuests = _loadGuests();    
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: const Color(0xffF5F6FA),
      appBar: AppBar(
        title: const Text(
            'Checkout Reports',
            style: TextStyle(
                fontWeight: FontWeight.w600,
            ),
            ),
        backgroundColor: Colors.white,
        elevation: 1,
      ),

      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _futureGuests,
        builder: (context, snapshot) {
            /// 🔄 LOADING
            if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
            }

            /// ERROR
            if (snapshot.hasError) {
            return Center(
                child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                    Text(snapshot.error.toString()),
                    const SizedBox(height: 10),
                    ElevatedButton(
                    onPressed: () {
                        setState(() {
                        _futureGuests = _loadGuests();
                        });
                    },
                    child: const Text("Retry"),
                    ),
                ],
                ),
            );
            }

            final guests = snapshot.data ?? [];

            /// 📭 EMPTY
            if (guests.isEmpty) {
            return const Center(
                child: Text('No guests checking out soon.'),
            );
            }

            /// ✅ DATA
            return RefreshIndicator(
            onRefresh: () async {
                setState(() {
                _futureGuests = _loadGuests();
                });
            },
            child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: guests.length,
                itemBuilder: (context, index) {
                return _buildGuestCard(guests[index]);
                },
            ),
            );
        },
        ),

    );
  }

  Widget _buildGuestCard(Map<String, dynamic> guest) {
    final today = DateTime.now();
    final checkoutDate = _parseDate(guest['checkoutDate']);
    final isToday = checkoutDate != null &&
        checkoutDate.year == today.year &&
        checkoutDate.month == today.month &&
        checkoutDate.day == today.day;

    return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
            BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
            ),
        ],
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            /// 🔹 HEADER
            Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                /// LEFT SIDE
                Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    /// Guest Name + ID
                    Text(
                        "${guest['guestName'] ?? 'Guest'} (ID: ${guest['guestId'] ?? '-'})",
                        style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        ),
                    ),

                    const SizedBox(height: 6),

                    /// Phone
                    Row(
                        children: [
                        const Icon(Icons.phone, size: 14, color: Colors.grey),
                        const SizedBox(width: 6),
                        Text(
                            (guest['contact'] == null || guest['contact'].toString().isEmpty)
                                ? "No contact"
                                : guest['contact'],
                            style: const TextStyle(
                            fontSize: 13,
                            color: Colors.grey,
                            ),
                        ),
                        ],
                    ),
                    ],
                ),
                ),

                /// RIGHT SIDE → ROOM BADGE
                Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                    color: Colors.amber.shade100,
                    borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                    "Room ${guest['roomNumber']}",
                    style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                ),
            ],
            ),

            /// 🔹 CHECKOUT BOX (Styled like status blocks in food page)
            Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: isToday
                    ? Colors.red.withOpacity(0.08)
                    : Colors.blue.withOpacity(0.05),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                color: isToday
                    ? Colors.red.withOpacity(0.3)
                    : Colors.blue.withOpacity(0.2),
                ),
            ),
            child: Row(
                children: [
                Icon(
                    Icons.logout,
                    color: isToday ? Colors.red : Colors.blue,
                    size: 18,
                ),
                const SizedBox(width: 10),

                Expanded(
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        Text(
                        guest['checkoutStatus'] ?? (isToday ? "Today" : "Upcoming"),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isToday ? Colors.red : Colors.blue,
                        ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                        _formatDate(guest['checkoutDate']),
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                        ),
                        ),
                    ],
                    ),
                ),
                ],
            ),
            ),
        ],
        ),
    );
    }

    String _formatDate(String? dateStr) {
    final date = _parseDate(dateStr);
    if (date == null) return 'Unknown';

    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year;

    final hour = date.hour > 12 ? date.hour - 12 : date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? 'PM' : 'AM';

    return "$day/$month/$year • ${hour == 0 ? 12 : hour}:$minute $period";
    }
}