import 'package:flutter/material.dart';
import 'camera_content_page.dart';
import '../services/rooms_service.dart';

import '../components/app_dialog.dart';
import '../components/empty_state_widget.dart';
import '../components/loading_widget.dart';
import '../utils/app_snackbar.dart';
import '../theme/app_typography.dart';
import '../theme/app_colors.dart';

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
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    _loadContents();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
    return _contents.where((item) {
      final searchMatch = _searchQuery.isEmpty ||
          (item["fullName"] ?? "")
              .toLowerCase()
              .contains(_searchQuery.toLowerCase());
      return searchMatch;
    }).toList();
  }

  Future<bool> _confirmDelete(Map item) async {
    final id = item["id"];
    if (id == null) return false;

    final confirm = await AppDialog.show(
      context,
      title: "Delete Content?",
      message: "This cannot be undone.",
      confirmLabel: "Delete",
      isDestructive: true,
    );

    if (confirm != true) return false;

    final result = await _roomsService.deleteContent(contentId: id);

    if (!mounted) return false;

    if (result["success"] == true) {
      // Remove in-place — stays on MyContentsPage
      setState(() => _contents.removeWhere((e) => e["id"] == id));
      AppSnackBar.show(context, result["message"] ?? "Content deleted");
      return true;
    } else {
      AppSnackBar.show(context, result["message"] ?? "Failed to delete content", isError: true);
      return false;
    }
  }

  // Triggered by ContentCard after a successful edit.
  // Reloads the list without leaving the page.
  void _onEditComplete() {
    _loadContents();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: AppBar(
        title: const Text("My Contents", style: AppTypography.appBarTitle),
      ),
      body: Column(
        children: [
          _searchBar(),
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
          prefixIcon:
              Icon(Icons.search, color: AppColors.textSecondary),
          filled: true,
          fillColor: AppColors.bgLight,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const LoadingWidget();
    }

    if (_error != null) {
      return Center(
          child: Text(_error!,
              style: TextStyle(color: AppColors.error)));
    }

    if (_filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined,
                size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text("No content available",
                style: AppTypography.bodySecondary.copyWith(color: Colors.grey, fontSize: 15)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadContents,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _filtered.length,
        itemBuilder: (_, i) {
          final item = _filtered[i];
          return ContentCard(
            content: item,
            onDeleteTap: () => _confirmDelete(item),
            onEditComplete: _onEditComplete,
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class ContentCard extends StatelessWidget {
  final Map<String, dynamic> content;
  final Future<bool> Function() onDeleteTap;
  final VoidCallback onEditComplete;

  const ContentCard({
    super.key,
    required this.content,
    required this.onDeleteTap,
    required this.onEditComplete,
  });

  void _previewImage(BuildContext context, String url) {
    final rooms = content["rooms"] as List? ?? [];

    showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InteractiveViewer(
              child: Image.network(url, fit: BoxFit.contain),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    content["fullName"] ?? "",
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 10),
                  if (rooms.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: rooms.map<Widget>((room) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
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

  Widget _iconButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 18),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = content["guestPhoto"] ?? "";
    final rooms = content["rooms"] as List? ?? [];

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Thumbnail ───────────────────────────────────────────────
          if (url.isNotEmpty)
            GestureDetector(
              onTap: () => _previewImage(context, url),
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
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Action row ─────────────────────────────────────────
                Row(
                  children: [
                    const Spacer(),

                    // DELETE — in-place removal, no navigation
                    _iconButton(
                      icon: Icons.delete_outline,
                      color: Colors.red,
                      onTap: onDeleteTap,
                    ),

                    const SizedBox(width: 6),

                    // EDIT — pushes CameraContentPage in edit mode.
                    // .then() fires when the edit screen pops:
                    //   refreshNeeded == true  → successful edit, reload list
                    //   refreshNeeded == null  → user cancelled, do nothing
                    _iconButton(
                      icon: Icons.edit_outlined,
                      color: AppColors.primary,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CameraContentPage(
                              existingContent: content,
                            ),
                          ),
                        ).then((refreshNeeded) {
                          if (refreshNeeded == true) {
                            onEditComplete();
                          }
                        });
                      },
                    ),
                  ],
                ),

                // ── Room chips ─────────────────────────────────────────
                if (rooms.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: rooms.map<Widget>((room) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          "Room ${room["room_number"]}",
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}


