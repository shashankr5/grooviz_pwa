import 'package:flutter/material.dart';
import '../services/home_service.dart';
import 'guest_checkout_page.dart';
import 'ticket_details_page.dart';
import 'profile_page.dart';
import '../utils/user_session_helper.dart';
import '../utils/app_snackbar.dart';


class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  String selectedFilter = "All";
  String selectedDateFilter = "All Days";
  String userName = "";
  int? loggedInUserId;
  int _currentTabIndex = 0;

  bool _isLoading = true;
  String? _errorMessage;
  bool _deptLoaded = false;
  late TabController _tabController;

  // Food Orders
  bool isRoomServiceUser = false;
  bool _foodLoading = true;
  String? _foodError;
  String selectedFoodFilter = "Ready";

  List<Map<String, dynamic>> tasks = [];

  final List<Map<String, dynamic>> readyOrders = [];
  final List<Map<String, dynamic>> acceptedOrders = [];
  final List<Map<String, dynamic>> deliveredOrders = [];
  int get currentSectionCount => filteredTasks.length;

  @override
  void initState() {
    super.initState();

    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging == false) {
        _currentTabIndex = _tabController.index;
      }
    });

    _loadUserId();
    _loadUserName();
    _loadTasks();
    _initDepartmentsAndFood();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadUserId() async {
    loggedInUserId = await UserSessionHelper.getUserId();
    if (mounted) {
      setState(() {}); // forces activeTasks to recalc
    }
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

  void _showGenericError() {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Something went wrong. Please try again."),
      ),
    );
  }

  ButtonStyle _taskButtonStyle(Color bgColor) {
    return ElevatedButton.styleFrom(
      backgroundColor: bgColor,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    );
  }

  DateTime _parseTimestamp(String? ts) {
    if (ts == null || ts.trim().isEmpty) {
      return DateTime.now();
    }

    try {
      String fixed = ts.trim();

      // Convert MySQL format → ISO
      if (fixed.contains(" ") && !fixed.contains("T")) {
        fixed = fixed.replaceFirst(" ", "T");
      }

      // DO NOT convert timezone
      return DateTime.parse(fixed);

    } catch (e) {
      debugPrint("❌ Timestamp parse failed: $ts");
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

  String formatDateTime(String ts) {
    if (ts.isEmpty) return "";

    final date = _parseTimestamp(ts);

    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year;

    final hour12 = date.hour > 12 ? date.hour - 12 : date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? "PM" : "AM";

    return "$day/$month/$year • ${hour12 == 0 ? 12 : hour12}:$minute $period";
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

    Duration diff = now.difference(createdAt);

    if (diff.isNegative) {
      diff = Duration.zero;
    }

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

  Future<void> _loadFoodByFilter(String filter) async {
    switch (filter) {
      case "Ready":
        await _loadReadyOrders();
        break;
      case "Accepted":
        await _loadAcceptedOrders();
        break;
      case "Delivered":
        await _loadDeliveredOrders();
        break;
    }
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

    if (result["success"] != true) {
      setState(() {
        _errorMessage = "Unable to load tasks.";
        _isLoading = false;
      });
      return;
    }

    final List<Map<String, dynamic>> rawList =
    List<Map<String, dynamic>>.from(result["tasks"]);

    final Map<int, Map<String, dynamic>> uniqueMap = {};

    for (final t in rawList) {
      final id = t["service_request_id"];
      if (id == null) continue;

      if (!uniqueMap.containsKey(id)) {
        uniqueMap[id] = t;
      } else {
        final existing = uniqueMap[id]!;

        final existingRoom = existing["room"];
        final newRoom = t["room"];

        // Prefer the record that has a valid room
        if ((existingRoom == null || existingRoom == "-" || existingRoom == "0") &&
            newRoom != null &&
            newRoom != "-" &&
            newRoom != "0") {
          uniqueMap[id] = t;
        }
      }
    }

    final List<Map<String, dynamic>> raw = uniqueMap.values.toList();

    raw.sort((a, b) {
      final da = _parseTimestamp(a["raw"]["created_at"] ?? a["created_at"]);
      final db = _parseTimestamp(b["raw"]["created_at"] ?? b["created_at"]);
      return db.compareTo(da);
    });

    setState(() {
      tasks = raw.map((t) {
        return {
          ...t,
          "isAccepted": t["status"] == "In Progress",
          "statusColor": getStatusColor(t["status"]),
          "assignedTo": t["raw"]?["assigned_to_name"] ?? "-",
        };
      }).toList();

      _isLoading = false;
    });
  }

  Future<void> _loadUserDepartments() async {
    final depts = await UserSessionHelper.getDepartments();

    debugPrint("🔥 RAW DEPARTMENTS = $depts");

    final normalized = depts
        .map((e) => e.toLowerCase().trim())
        .toList();

    if (!mounted) return;

    setState(() {
      isRoomServiceUser = normalized.any((d) {
        return d.contains("room") && d.contains("service");
      });

      debugPrint("🔥 isRoomServiceUser = $isRoomServiceUser");
      _deptLoaded = true;
    });
  }

  Future<void> _initDepartmentsAndFood() async {
    await _loadUserDepartments();

    if (isRoomServiceUser) {
      _loadReadyOrders();
      _loadAcceptedOrders();
      _loadDeliveredOrders();
    }
  }

  Future<void> _acceptTask(Map<String, dynamic> task) async {
    final taskId = task["raw"]?["service_request_id"];
    if (taskId == null) return;

    setState(() => _isLoading = true);

    final result = await HomeService().acceptTask(taskId: taskId);

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (!result["success"]) {
      _showGenericError();
      return;
    }

    await _loadTasks();

    AppSnackBar.show(context, "Task Accepted 🎉");
  }


  List<Map<String, dynamic>> get filteredTasks {
    if (loggedInUserId == null) return [];

    List<Map<String, dynamic>> list;

    switch (selectedFilter) {
      case "Open":
        list = tasks.where((t) => t["status"] == "Open").toList();
        break;

      case "In Progress":
        list = tasks.where((t) => t["status"] == "In Progress").toList();
        break;

      case "Closed":
        list = tasks.where((t) => t["status"] == "Closed").toList()
          ..sort((a, b) {
            final da = _parseTimestamp(a["raw"]["created_at"] ?? "");
            final db = _parseTimestamp(b["raw"]["created_at"] ?? "");
            return db.compareTo(da);
          });
        break;

      default:
        list = tasks.where((t) => t["status"] != "Closed").toList()
          ..sort((a, b) {
            final da = _parseTimestamp(a["raw"]["created_at"] ?? "");
            final db = _parseTimestamp(b["raw"]["created_at"] ?? "");
            return db.compareTo(da);
          });
    }

    return list.where((t) {
      final createdAt = t["raw"]?["created_at"] ?? "";
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
    if (loggedInUserId == null) return [];

    return tasks.where((t) {
      final assignedToId =
      int.tryParse("${t["raw"]?["assigned_to"]}");
      return assignedToId == loggedInUserId &&
          (t["status"] == "Open" || t["status"] == "In Progress");
    }).toList();
  }

  Future<void> _loadReadyOrders() async {
    setState(() {
      _foodLoading = true;
      _foodError = null;
    });

    final result = await HomeService().getReadyOrdersForRoomService();

    if (!mounted) return;

    if (result["success"] != true) {
      setState(() {
        _foodError = "Unable to load orders.";
        _foodLoading = false;
      });
      return;
    }

    final grouped = _groupReadyOrders(
      List<Map<String, dynamic>>.from(result["orders"]),
    );

    setState(() {
      readyOrders
        ..clear()
        ..addAll(
          grouped.map((o) => {
            ...o,
            "uiStatus": "Ready",
          }),
        );

      _foodLoading = false;
    });
  }

  Future<void> _acceptFood(Map<String, dynamic> food) async {
    final res = await HomeService().updateRoomServiceStatus(
      orderNumber: food["orderNumber"],
      action: "Accept",
    );

    if (!res["success"]) {
      _showGenericError();
      return;
    }

    // ALWAYS reload from backend
    await _loadReadyOrders();
    await _loadAcceptedOrders();
    await _loadDeliveredOrders();

    AppSnackBar.show(context, "Order accepted");
  }

  Future<void> _deliverFood(Map<String, dynamic> food) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Confirm Delivery"),
        content: const Text("Mark this order as delivered?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Deliver"),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final res = await HomeService().updateRoomServiceStatus(
      orderNumber: food["orderNumber"],
      action: "Delivered",
    );

    if (res["success"] != true) {
      _showGenericError();
      return;
    }

    // reload authoritative state
    await _loadReadyOrders();
    await _loadAcceptedOrders();
    await _loadDeliveredOrders();

    AppSnackBar.show(context, "Order delivered successfully");
  }


  List<Map<String, dynamic>> _groupReadyOrders(List<Map<String, dynamic>> apiOrders) {
    final Map<String, Map<String, dynamic>> grouped = {};

    for (final o in apiOrders) {
      final orderNo = o["orderNumber"];

      if (!grouped.containsKey(orderNo)) {
        grouped[orderNo] = {
          "orderNumber": orderNo,
          "roomNumber": o["roomNumber"],
          "guestName": o["guestName"],
          "status": o["status"],
          "items": [],
          "orderTime": o["orderTime"],
          "raw": o["raw"],
        };
      }

      grouped[orderNo]!["items"].add({
        "name": o["foodItem"],
        "qty": o["quantity"],
      });
    }

    return grouped.values.toList();
  }

  Future<void> _loadAcceptedOrders() async {
    setState(() => _foodLoading = true);

    final result = await HomeService().getAcceptedOrdersForRoomService();

    if (!mounted) return;

    if (result["success"] != true) {
      setState(() => _foodLoading = false);
      _showGenericError();
      return;
    }

    final grouped = _groupAcceptedOrders(
      List<Map<String, dynamic>>.from(result["orders"]),
    );

    setState(() {
      acceptedOrders
        ..clear()
        ..addAll(grouped.map((o) => {...o, "uiStatus": "Accepted"}));

      _foodLoading = false;
    });
  }

  List<Map<String, dynamic>> _groupAcceptedOrders(List<Map<String, dynamic>> apiOrders) {
    final Map<String, Map<String, dynamic>> grouped = {};

    for (final o in apiOrders) {
      final orderNo = o["orderNumber"];

      if (!grouped.containsKey(orderNo)) {
        grouped[orderNo] = {
          "orderNumber": orderNo,
          "roomNumber": o["roomNumber"],
          "guestName": o["guestName"],
          "status": o["status"],
          "items": [],
          "orderTime": o["orderTime"],
          "raw": o["raw"],
        };
      }

      grouped[orderNo]!["items"].add({
        "name": o["foodItem"],
        "qty": o["quantity"],
      });
    }

    return grouped.values.toList();
  }

  Future<void> _loadDeliveredOrders() async {
    setState(() => _foodLoading = true);

    final result = await HomeService().getDeliveredOrdersForRoomService();

    if (!mounted) return;

    if (result["success"] != true) {
      setState(() => _foodLoading = false);
      _showGenericError();
      return;
    }

    final grouped = _groupDeliveredOrders(
      List<Map<String, dynamic>>.from(result["orders"]),
    );

    setState(() {
      deliveredOrders
        ..clear()
        ..addAll(grouped.map((o) => {...o, "uiStatus": "Delivered"}));
      _foodLoading = false;
    });
  }

  List<Map<String, dynamic>> _groupDeliveredOrders(List<Map<String, dynamic>> apiOrders) {
    final Map<String, Map<String, dynamic>> grouped = {};

    for (final o in apiOrders) {
      final orderNo = o["orderNumber"];

      if (!grouped.containsKey(orderNo)) {
        grouped[orderNo] = {
          "orderNumber": orderNo,
          "roomNumber": o["roomNumber"],
          "guestName": o["guestName"],
          "status": o["status"],
          "items": [],
          "orderTime": o["orderTime"],
          "raw": o["raw"],
        };
      }

      grouped[orderNo]!["items"].add({
        "name": o["foodItem"],
        "qty": o["quantity"],
      });
    }

    return grouped.values.toList();
  }

  List<Map<String, dynamic>> get filteredFoodOrders {
    switch (selectedFoodFilter) {
      case "Ready":
        return readyOrders;
      case "Accepted":
        return acceptedOrders;
      case "Delivered":
        return deliveredOrders;
      default:
        return readyOrders;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_deptLoaded) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // 🔹 NON Room Service → ONLY TASKS (NO TABS)
    if (!isRoomServiceUser) {
      return Scaffold(
        backgroundColor: Colors.grey[100],
        appBar: _buildSimpleAppBar(),
        body: Stack(
          children: [
            _errorMessage != null ? _buildError() : _buildContent(),

            if (_isLoading)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black26,
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      );
    }

    // 🔹 Room Service → TASKS + FOOD TABS
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: _buildAppBarWithTabs(),
      body: Stack(
        children: [
          _errorMessage != null
              ? _buildError()
              : _buildTabsBody(),

          if (_isLoading)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black26,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  AppBar _buildSimpleAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.white,
      elevation: 1,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Welcome,",
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
          Text(
            "$userName 👋",
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  AppBar _buildAppBarWithTabs() {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.white,
      elevation: 1,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Welcome,",
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
          Text(
            "$userName 👋",
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const GuestCheckoutPage(),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                shape: BoxShape.circle,
              ),
              child: Image.asset(
                "assets/icons/checkout_report.png",
                width: 22,
                height: 22,
                color: Colors.black, // 🔥 remove if your icon is already colored
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(50),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ProfilePage(),
                  ),
                );
              },
              child: CircleAvatar(
                backgroundColor: Colors.deepPurple,
                child: Text(
                  userName.isNotEmpty
                      ? userName[0].toUpperCase()
                      : "?",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],

      // 👇 TAB BAR ADDED HERE
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Container(
            height: 45,
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(30),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.black87,
              indicator: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.all(Radius.circular(30)),
              ),
              tabs: [
                Tab(text: "Tasks"),
                Tab(text: "Food"),
              ],
            ),
          ),
        ),
      ),
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

  Widget _buildFoodTab() {
    if (_foodLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_foodError != null) {
      return Center(child: Text(_foodError!));
    }

    return Column(
      children: [
        const SizedBox(height: 16),

        // Filters
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: ["Ready", "Accepted", "Delivered"].map((f) {
            final selected = selectedFoodFilter == f;

            return GestureDetector(
              onTap: () async {
                if (selectedFoodFilter == f) return;

                setState(() => selectedFoodFilter = f);
                await _loadFoodByFilter(f);
              },
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 6),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? Colors.amber[700] : Colors.white,
                  borderRadius: BorderRadius.circular(25),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Text(
                  f,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.black,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          }).toList(),
        ),

        const SizedBox(height: 16),

        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              await _loadReadyOrders();
              await _loadAcceptedOrders();
              await _loadDeliveredOrders();
            },
            child: filteredFoodOrders.isEmpty
                ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 200),
                Center(child: Text("No orders")),
              ],
            )
                : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: filteredFoodOrders.length,
              itemBuilder: (context, index) {
                return _buildFoodCard(filteredFoodOrders[index]);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFoodCard(Map<String, dynamic> food) {
    final items = food["items"] as List;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black12.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Order ${food["orderNumber"]}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "Room ${food["roomNumber"]}",
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              _foodStatusPill(food["uiStatus"])
            ],
          ),

          const SizedBox(height: 10),
          const Divider(),
          // Items list
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: items.map<Widget>((i) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          i["name"],
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        "${i["qty"]}",
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,          // ← quantity is bold
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),

          const SizedBox(height: 6),

          Text(
            formatDateTime(food["orderTime"] ?? ""),
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),

          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (food["uiStatus"] == "Ready")
                ElevatedButton(
                  onPressed: () => _acceptFood(food),
                  style: _taskButtonStyle(Colors.green),
                  child: const Text("Accept"),
                ),

              if (food["uiStatus"] == "Accepted")
                ElevatedButton(
                  onPressed: () => _deliverFood(food),
                  style: _taskButtonStyle(Colors.indigo),
                  child: const Text("Deliver"),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _foodStatusPill(String status) {
    Color color;

    switch (status) {
      case "Ready":
        color = Colors.orange;
        break;
      case "Accepted":
        color = Colors.indigo;
        break;
      case "Delivered":
        color = Colors.green;
        break;
      default:
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color),
      ),
      child: Text(
        status,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
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
                  Text(
                    "$currentSectionCount ${selectedFilter == "All" ? "active" : selectedFilter.toLowerCase()} tickets",
                    style: TextStyle(fontSize: 14, color: Colors.grey[700]),
                  ),
                ],
              ),

              Theme(
                data: Theme.of(context).copyWith(
                  canvasColor: Colors.white,
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
                    DropdownMenuItem(value: "Today", child: Text("Today")),
                    DropdownMenuItem(value: "Yesterday", child: Text("Yesterday")),
                    DropdownMenuItem(value: "All Days", child: Text("All Days")),
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
                return KeyedSubtree(
                  key: ValueKey(task["raw"]["service_request_id"]),
                  child: GestureDetector(
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TicketDetailPage(
                            task: task,
                            onClose: () {
                              setState(() {
                                final idx = tasks.indexWhere((t) =>
                                t["raw"]["service_request_id"] ==
                                    task["raw"]["service_request_id"]);
                                if (idx != -1) {
                                  tasks[idx]["status"] = "Closed";
                                  tasks[idx]["statusColor"] =
                                      getStatusColor("Closed");
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
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilters() {
    final filters = ["All", "Open", "In Progress", "Closed"];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: filters.map((text) {
          final selected = selectedFilter == text;

          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => selectedFilter = text),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? Colors.amber[700] : Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Center(
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTabsBody() {
    return TabBarView(
      controller: _tabController,
      children: [
        _buildContent(),
        _buildFoodTab(),
      ],
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
                      children: [
                        Text(
                          formatDateTime(createdAt),
                          style: TextStyle(color: Colors.grey[600], fontSize: 13),
                        ),
                        const Spacer(),
                        if (task["status"] == "Open")
                          ElevatedButton(
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
          style: TextStyle(
              color: textColor, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }
}