import 'package:flutter/material.dart';
import 'profile_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: CustomScrollView(
        slivers: [
          // ---- Dynamic Sliver AppBar ----
          SliverAppBar(
            pinned: true,
            backgroundColor: Colors.deepPurple,
            elevation: 0,
            expandedHeight: topPadding + 50,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      "Welcome Back, Shashank!",
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const CircleAvatar(
                    radius: 14,
                    backgroundColor: Colors.white,
                    child: Icon(Icons.person,
                        color: Colors.deepPurple, size: 20),
                  ),
                ],
              ),
            ),
          ),

          // ---- Dashboard Metrics ----
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                height: 120,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _metricCard(
                        "Pending Tasks", "12", Icons.pending_actions, Colors.orange),
                    _metricCard("Completed", "32", Icons.check_circle, Colors.green),
                    _metricCard("New Requests", "5", Icons.notifications, Colors.red),
                    _metricCard("Departments", "3", Icons.group_work, Colors.blue),
                  ],
                ),
              ),
            ),
          ),

          // ---- Quick Actions ----
          SliverPadding(
            padding: const EdgeInsets.only(left: 16, bottom: 24),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Quick Actions",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 120,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _quickAction(
                          "View Requests",
                          Icons.notifications_active,
                          Colors.deepPurple,
                          onTap: () => _showRequestsBottomSheet(context),
                        ),
                        _quickAction(
                          "My Tasks",
                          Icons.assignment,
                          Colors.teal,
                          onTap: () => _showTaskListSheet(context),
                        ),
                        _quickAction(
                          "Task History",
                          Icons.history,
                          Colors.brown,
                          onTap: () {},
                        ),

                        // ✅ UPDATED SETTINGS ACTION
                        _quickAction(
                          "Settings",
                          Icons.settings,
                          Colors.indigo,
                          onTap: () => _showSettingsSheet(context),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ---- Recent Notifications ----
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const Text(
                  "Recent Notifications",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),

                _notificationCard(
                    "Room 204 requested Room Cleaning.", "Housekeeping", Colors.orange),
                _notificationCard(
                    "Guest reported a TV issue.", "Maintenance", Colors.red),
                _notificationCard(
                    "New food order from Room 118.", "Food Service", Colors.green),

                const SizedBox(height: 24),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // ✅ Metric Card
  Widget _metricCard(String title, String value, IconData icon, Color color) {
    return Container(
      width: 120,
      margin: const EdgeInsets.only(right: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.7), color],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: color.withOpacity(0.3),
              blurRadius: 6,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Colors.white24,
            child: Icon(icon, color: Colors.white, size: 20),
          ),
          const Spacer(),
          Text(title,
              style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w500,
                  fontSize: 12)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ✅ Quick Action Card
  Widget _quickAction(String label, IconData icon, Color color,
      {required VoidCallback onTap}) {
    return Container(
      width: 120,
      margin: const EdgeInsets.only(right: 16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 32, color: color),
            const SizedBox(height: 10),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(color: color, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  // ✅ Notification Card
  Widget _notificationCard(String message, String dept, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black12,
              blurRadius: 8,
              spreadRadius: 1,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Row(
        children: [
          Container(
            height: 14,
            width: 14,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message,
                    style:
                        const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.apartment, size: 18, color: color),
                    const SizedBox(width: 6),
                    Text(dept,
                        style: TextStyle(color: Colors.grey[700], fontSize: 13)),
                  ],
                ),
              ],
            ),
          ),

          Icon(Icons.chevron_right, color: Colors.grey[600]),
        ],
      ),
    );
  }

  // ✅ REQUESTS Bottom Sheet
  void _showRequestsBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (_, controller) {
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              ),
              child: Column(
                children: [
                  Container(
                    width: 45,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),

                  const Text("All Requests",
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),

                  Expanded(
                    child: ListView(
                      controller: controller,
                      children: [
                        _requestTile(
                            "Room 204", "Room Cleaning", "Pending", Colors.orange),
                        _requestTile("Room 118", "Food Order", "In Progress",
                            Colors.green),
                        _requestTile(
                            "Room 510", "TV Issue", "Pending", Colors.red),
                        _requestTile("Room 303", "Laundry Pickup", "Completed",
                            Colors.blue),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _requestTile(String room, String type, String status, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: const Offset(0, 3)),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(radius: 10, backgroundColor: color),
          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(room,
                    style:
                        const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Text(type, style: TextStyle(color: Colors.grey[600])),
              ],
            ),
          ),

          Text(status, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  // ✅ TASK LIST BOTTOM SHEET
  void _showTaskListSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.60,
          builder: (_, scrollController) {
            return _taskListPage(scrollController, context);
          },
        );
      },
    );
  }

  // ✅ TASK PAGE with FILTERS
  Widget _taskListPage(ScrollController controller, BuildContext context) {
    List<String> filters = [
      "All",
      "Pending",
      "In Progress",
      "Completed",
      "High Priority"
    ];

    ValueNotifier<String> selectedFilter = ValueNotifier("All");

    List<Map<String, dynamic>> tasks = [
      {
        "room": "204",
        "title": "Room Cleaning",
        "status": "Pending",
        "priority": "High",
        "color": Colors.orange
      },
      {
        "room": "118",
        "title": "Food Order",
        "status": "In Progress",
        "priority": "Medium",
        "color": Colors.green
      },
      {
        "room": "510",
        "title": "TV Issue Repair",
        "status": "Completed",
        "priority": "Low",
        "color": Colors.blue
      },
    ];

    return StatefulBuilder(builder: (context, setState) {
      List<Map<String, dynamic>> filteredTasks = tasks.where((task) {
        if (selectedFilter.value == "All") return true;
        if (selectedFilter.value == "High Priority") {
          return task["priority"] == "High";
        }
        return task["status"] == selectedFilter.value;
      }).toList();

      return Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),

            Container(
              width: 45,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(20),
              ),
            ),

            const SizedBox(height: 10),

            const Text("Tasks",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),

            // ✅ FILTER BAR
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: filters.map((filter) {
                  bool isSelected = selectedFilter.value == filter;

                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        selectedFilter.value = filter;
                      });
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 10),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.deepPurple
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        filter,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.black87,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

            const SizedBox(height: 12),

            // ✅ TASK LIST
            Expanded(
              child: ListView.builder(
                controller: controller,
                itemCount: filteredTasks.length,
                padding: const EdgeInsets.all(16),
                itemBuilder: (context, index) {
                  final task = filteredTasks[index];

                  return GestureDetector(
                    onTap: () => _showTaskDetails(context, task),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black12,
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          )
                        ],
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 10,
                            backgroundColor: task["color"],
                          ),
                          const SizedBox(width: 12),

                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Room ${task["room"]}",
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16)),
                                const SizedBox(height: 4),
                                Text(task["title"],
                                    style:
                                        TextStyle(color: Colors.grey.shade600)),
                              ],
                            ),
                          ),

                          Text(
                            task["status"],
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: task["color"]),
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
      );
    });
  }

  // ✅ TASK DETAILS SHEET
  void _showTaskDetails(BuildContext context, Map task) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 45,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),

              Text(task["title"],
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),

              Text("Room ${task["room"]}",
                  style:
                      TextStyle(fontSize: 16, color: Colors.grey.shade700)),
              const SizedBox(height: 14),

              Row(
                children: [
                  Icon(Icons.flag, color: task["color"]),
                  const SizedBox(width: 8),
                  Text("Priority: ${task["priority"]}",
                      style: TextStyle(
                        fontSize: 15,
                        color: task["color"],
                        fontWeight: FontWeight.bold,
                      )),
                ],
              ),

              const SizedBox(height: 20),

              Row(
                children: [
                  _actionButton("Accept", Colors.blue, () {}),
                  const SizedBox(width: 10),
                  _actionButton("Start", Colors.orange, () {}),
                  const SizedBox(width: 10),
                  _actionButton("Complete", Colors.green, () {}),
                ],
              ),

              const SizedBox(height: 30),

              const Text("Task Notes",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),

              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    "Here you can add detailed notes about this task.",
                    style:
                        TextStyle(color: Colors.grey.shade600, height: 1.4),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ✅ ACTION BUTTONS
  Widget _actionButton(String text, Color color, VoidCallback onTap) {
    return Expanded(
      child: SizedBox(
        height: 42,
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  // ✅ ✅ ✅ SETTINGS BOTTOM SHEET
  void _showSettingsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.70,
          maxChildSize: 0.95,
          minChildSize: 0.60,
          builder: (_, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Container(
                    width: 45,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),

                  const Text(
                    "Settings",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),

                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      children: [
                        _settingsSectionTitle("Profile & Account"),

                        _settingsTile(
                          icon: Icons.person,
                          title: "Edit Profile",
                          onTap: () {},
                        ),

                        _settingsTile(
                          icon: Icons.lock,
                          title: "Change Password",
                          onTap: () {},
                        ),

                        _settingsTile(
                          icon: Icons.access_time_filled,
                          title: "My Shift Timings",
                          onTap: () {},
                        ),

                        _settingsTile(
                          icon: Icons.apartment,
                          title: "My Departments",
                          subtitle: "You can select multiple",
                          onTap: () => _showDepartmentsSelector(context),
                        ),

                        const SizedBox(height: 20),
                        _settingsSectionTitle("System"),

                        _settingsTile(
                          icon: Icons.logout,
                          title: "Logout",
                          color: Colors.red,
                          onTap: () {},
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ✅ SETTINGS TILE UI
  Widget _settingsTile({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    Color? color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, size: 24, color: color ?? Colors.deepPurple),
            const SizedBox(width: 16),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: color ?? Colors.black87,
                      )),
                  if (subtitle != null)
                    Text(subtitle!,
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 13)),
                ],
              ),
            ),

            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  // ✅ Section Title
  Widget _settingsSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.black54,
        ),
      ),
    );
  }

  // ✅ Multi-select department popup
  void _showDepartmentsSelector(BuildContext context) {
    List<String> departments = [
      "Housekeeping",
      "Maintenance",
      "Food Service",
      "Laundry"
    ];

    List<String> selected = [];

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text("Select Departments"),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: departments.map((dept) {
                  bool isSelected = selected.contains(dept);

                  return CheckboxListTile(
                    value: isSelected,
                    title: Text(dept),
                    onChanged: (value) {
                      setState(() {
                        value! ? selected.add(dept) : selected.remove(dept);
                      });
                    },
                  );
                }).toList(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text("Save"),
              )
            ],
          );
        });
      },
    );
  }
}
