import 'package:flutter/material.dart';
import 'camera_content_page.dart';
import '../services/rooms_service.dart';

enum ContentFilter { all, live, scheduled, expired }

class MyContentsPage extends StatefulWidget {
  const MyContentsPage({super.key});

  @override
  State<MyContentsPage> createState() => _MyContentsPageState();
}

class _MyContentsPageState extends State<MyContentsPage> {
  final RoomsService _roomsService = RoomsService();
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _contents = [];
  bool _isLoading = true;
  String? _error;

  ContentFilter _filter = ContentFilter.all;
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    _loadContents();
  }

  Future<void> _loadContents() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final res = await _roomsService.getContents();

    if (!mounted) return;

    if (res["success"]) {
      setState(() {
        _contents = List<Map<String, dynamic>>.from(res["contents"]);
        _isLoading = false;
      });
    } else {
      setState(() {
        _error = res["message"];
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final now = DateTime.now();

    return _contents.where((item) {
      final start = DateTime.tryParse(item["startTime"] ?? "");
      final end = DateTime.tryParse(item["endTime"] ?? "");

      bool filterMatch = true;

      if (_filter != ContentFilter.all && start != null && end != null) {
        switch (_filter) {
          case ContentFilter.live:
            filterMatch = now.isAfter(start) && now.isBefore(end);
            break;
          case ContentFilter.scheduled:
            filterMatch = now.isBefore(start);
            break;
          case ContentFilter.expired:
            filterMatch = now.isAfter(end);
            break;
          default:
            break;
        }
      }

      final searchMatch = _searchQuery.isEmpty ||
          (item["title"] ?? "")
              .toLowerCase()
              .contains(_searchQuery.toLowerCase());

      return filterMatch && searchMatch;
    }).toList();
  }

  Future<bool> _confirmDelete(Map item) async {
    final id = item["id"];
    if (id == null) return false;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Delete Content?"),
        content: const Text("This cannot be undone."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (confirm != true) return false;

    final result = await _roomsService.deleteContent(
      contentId: id,
    );

    if (!mounted) return false;

    if (result["success"]) {
      setState(() => _contents.removeWhere((e) => e["id"] == id));

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result["message"]),
          backgroundColor: Colors.green,
        ),
      );
      return true;
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result["message"]),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text("My Contents",
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black),
        elevation: 1,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const CameraContentPage()),
              );
              _loadContents();
            },
          )
        ],
      ),
      body: Column(
        children: [
          _searchBar(),
          _filterTabs(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _searchQuery = v),
        decoration: InputDecoration(
          hintText: "Search contents...",
          prefixIcon: const Icon(Icons.search),
          filled: true,
          fillColor: Colors.grey[100],
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none),
        ),
      ),
    );
  }

  Widget _filterTabs() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: ContentFilter.values.map((f) {
          final selected = _filter == f;
          return GestureDetector(
            onTap: () => setState(() => _filter = f),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? Colors.black : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                f.name[0].toUpperCase() + f.name.substring(1),
                style: TextStyle(
                    color: selected ? Colors.white : Colors.black,
                    fontWeight: FontWeight.w600),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }

    if (_filtered.isEmpty) {
      return const Center(child: Text("No contents found"));
    }

    return RefreshIndicator(
      onRefresh: _loadContents,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _filtered.length,
        itemBuilder: (_, i) {
          final item = _filtered[i];

          return Dismissible(
            key: Key(item["id"]),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: Colors.red,
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            confirmDismiss: (_) => _confirmDelete(item),
            child: ContentCard(content: item),
          );
        },
      ),
    );
  }
}

class ContentCard extends StatelessWidget {
  final Map<String, dynamic> content;

  const ContentCard({super.key, required this.content});

  void _previewImage(BuildContext context, String url, Map content) {
    final rooms = content["rooms"] as List? ?? [];

    showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            /// IMAGE
            InteractiveViewer(
              child: Image.network(url, fit: BoxFit.contain),
            ),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  /// STATUS
                  _statusBadge(content),
                  const SizedBox(height: 12),

                  /// ROOMS
                  if (rooms.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: rooms.map<Widget>((room) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.amber[700],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            "Room ${room["room_number"]}",
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = content["filePath"] ?? "";
    final title = content["title"] ?? "Untitled";

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          /// IMAGE (clickable)
          if (url.isNotEmpty)
            GestureDetector(
              onTap: () => _previewImage(context, url, content),
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(18)),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(url, fit: BoxFit.cover),
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [

                /// TITLE
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                /// DELETE
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  color: Colors.red,
                  onPressed: () async {
                    final state =
                        context.findAncestorStateOfType<_MyContentsPageState>();

                    if (state != null) {
                      await state._confirmDelete(content);
                    }
                  },
                ),

                /// EDIT
                TextButton.icon(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CameraContentPage(
                          existingContent: content,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text("Edit"),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(Map content) {
    final now = DateTime.now();
    final start = DateTime.tryParse(content["startTime"] ?? "");
    final end = DateTime.tryParse(content["endTime"] ?? "");

    String label = "Unknown";
    Color color = Colors.grey;

    if (start != null && end != null) {
      if (now.isBefore(start)) {
        label = "Scheduled";
        color = Colors.blue;
      } else if (now.isAfter(end)) {
        label = "Expired";
        color = Colors.grey;
      } else {
        label = "Live";
        color = Colors.green;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 12),
      ),
    );
  }

  String _shortDate(dynamic v) {
    final d = DateTime.tryParse(v ?? "");
    if (d == null) return "—";
    return "${d.day}/${d.month}";
  }
}