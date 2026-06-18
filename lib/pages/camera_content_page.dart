// camera_content_page.dart

import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

import 'my_contents_page.dart';
import '../services/rooms_service.dart';
import '../services/upload_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/app_colors.dart';
import '../utils/app_snackbar.dart';

class CameraContentPage extends StatefulWidget {
  final Map<String, dynamic>? existingContent;

  const CameraContentPage({super.key, this.existingContent});

  @override
  State<CameraContentPage> createState() => _CameraContentPageState();
}

class _CameraContentPageState extends State<CameraContentPage> {
  final ImagePicker _picker = ImagePicker();
  File? _selectedImage;
  Set<String> _selectedRooms = {};

  bool get _isEditMode => widget.existingContent != null;
  String? _existingImageUrl;
  int? _contentId;

  final RoomsService _roomsService = RoomsService();

  List<Map<String, dynamic>> _rooms = [];
  bool _isLoadingRooms = true;
  String? _roomsError;

  bool _isUploading = false;

  static const Color _accent = Color(0xFF5C6BC0);

  // ── Device IDs from selected rooms ────────────────────────────────────────

  List<int> _getSelectedDeviceIds() {
    final selectedRooms = _rooms.where((room) {
      final label = "Room ${room["roomNumber"]}";
      return _selectedRooms.contains(label);
    });

    return selectedRooms
        .expand((room) => room["devices"])
        .map<int>((d) => d["device_id"])
        .toSet()
        .toList();
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _fetchRooms();

    if (_isEditMode) {
      _prefillExistingData();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _toggleSelectAll() {
    setState(() {
      if (_selectedRooms.length == _rooms.length) {
        _selectedRooms.clear();
      } else {
        _selectedRooms = _rooms.map((r) => "Room ${r["roomNumber"]}").toSet();
      }
    });
  }

  /// Resets form — only used in edit mode via the Cancel button.
  void _resetForm() {
    setState(() {
      _selectedImage = null;
      _existingImageUrl = null;
      _selectedRooms.clear();
    });
  }

  Future<void> _fetchRooms() async {
    setState(() {
      _isLoadingRooms = true;
      _roomsError = null;
    });

    final result = await _roomsService.getRooms();

    if (!mounted) return;

    if (result["success"]) {
      final rooms = result["rooms"] as List;

      final occupiedRooms = rooms.where((room) {
        final status = (room["status"] ?? "").toString().toLowerCase();
        return status == "occupied";
      }).toList();

      setState(() {
        _rooms = List<Map<String, dynamic>>.from(occupiedRooms);
        _isLoadingRooms = false;
      });
    } else {
      setState(() {
        _roomsError = result["message"];
        _isLoadingRooms = false;
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image != null) {
        setState(() {
          _selectedImage = File(image.path);
        });
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, 'Error picking image: $e', isError: true);
      }
    }
  }

  // ── Image processing ──────────────────────────────────────────────────────

  img.Image _fitTo1920x1080(img.Image src) {
    const int targetW = 1920;
    const int targetH = 1080;

    final double scaleW = targetW / src.width;
    final double scaleH = targetH / src.height;
    final double scale = scaleW < scaleH ? scaleW : scaleH;

    final int scaledW = (src.width * scale).round();
    final int scaledH = (src.height * scale).round();

    final img.Image resized = img.copyResize(
      src,
      width: scaledW,
      height: scaledH,
      interpolation: img.Interpolation.cubic,
    );

    final img.Image canvas = img.Image(
      width: targetW,
      height: targetH,
      numChannels: 3,
    );

    img.fill(canvas, color: img.ColorRgb8(0, 0, 0));

    final int dx = ((targetW - scaledW) / 2).round();
    final int dy = ((targetH - scaledH) / 2).round();

    img.compositeImage(canvas, resized, dstX: dx, dstY: dy);

    return canvas;
  }

  // ── Upload ────────────────────────────────────────────────────────────────

  Future<void> _uploadContent() async {
    if (_isUploading) return;

    setState(() => _isUploading = true);

    final deviceIds = _getSelectedDeviceIds();

    if (deviceIds.isEmpty) {
      AppSnackBar.show(context, "No devices found for selected rooms",
          isError: true);
      setState(() => _isUploading = false);
      return;
    }

    if (_selectedImage == null && _existingImageUrl == null) {
      AppSnackBar.show(context, "Please select an image", isError: true);
      setState(() => _isUploading = false);
      return;
    }

    try {
      String finalUrl = _existingImageUrl ?? "";

      if (_selectedImage != null) {
        final originalBytes = await _selectedImage!.readAsBytes();

        final img.Image? decoded = img.decodeImage(originalBytes);
        if (decoded == null) {
          throw Exception("Invalid image");
        }

        final img.Image oriented = img.bakeOrientation(decoded);
        final img.Image tv = _fitTo1920x1080(oriented);

        final List<int> outputBytes = img.encodePng(tv);

        final String base64Image =
            "data:image/png;base64,${base64Encode(outputBytes)}";

        final enterpriseId =
            (await UserSessionHelper.getEnterpriseId())?.toString() ?? "";

        final uploadService = UploadService();

        final uploadResult = await uploadService.uploadBase64File(
          base64: base64Image,
          fileName: "camera_${DateTime.now().millisecondsSinceEpoch}.png",
          contentType: "IMAGE",
          enterpriseId: enterpriseId,
        );

        if (!uploadResult["success"]) {
          throw Exception(uploadResult["message"]);
        }

        finalUrl = uploadResult["url"];
      }

      final result = await _roomsService.updateGuestPhoto(
        filePath: finalUrl,
        deviceIds: deviceIds,
      );

      if (!mounted) return;

      if (result["success"]) {
        AppSnackBar.show(
            context, result["message"] as String? ?? "Uploaded successfully");

        if (_isEditMode) {
          // Pop back to MyContentsPage with refresh signal — stays on that page
          Navigator.pop(context, true);
        } else {
          // Upload mode: reset for next upload
          setState(() {
            _selectedImage = null;
            _selectedRooms.clear();
          });
        }
      } else {
        throw Exception(result["message"]);
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, "Upload failed: $e", isError: true);
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _removeImage() {
    // Clears the locally selected image in both upload and edit mode
    setState(() {
      _selectedImage = null;
    });
  }

  // ── Image picker bottom sheet ─────────────────────────────────────────────

  void _showImagePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(
                children: const [
                  Text(
                    "Add Photo",
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.borderLight),
            const SizedBox(height: 4),
            _pickerTile(
              context,
              icon: Icons.photo_library_outlined,
              label: "Choose from Gallery",
              subtitle: "Pick an existing photo",
              color: AppColors.primary,
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            _pickerTile(
              context,
              icon: Icons.camera_alt_outlined,
              label: "Take a Photo",
              subtitle: "Best in landscape mode",
              color: AppColors.textPrimary,
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _pickerTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(label,
          style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AppColors.textPrimary)),
      subtitle: Text(subtitle,
          style: const TextStyle(
              fontSize: 12, color: AppColors.textSecondary)),
      onTap: onTap,
    );
  }

  // ── Landscape dialog ──────────────────────────────────────────────────────

  Future<void> _showLandscapeDialog() async {
    final bool? proceed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 20),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.screen_rotation_outlined,
                    color: _accent, size: 32),
              ),
              const SizedBox(height: 16),
              const Text(
                "Hold in Landscape",
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              const Text(
                "Please hold your device sideways while taking the photo. "
                "This ensures the best viewing experience on TV screens.",
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                    height: 1.5),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppColors.border),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("Cancel",
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context, true),
                      icon: const Icon(Icons.camera_alt_rounded, size: 18),
                      label: const Text("Open Camera",
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (proceed == true) {
      _pickImage(ImageSource.camera);
    }
  }

  // ── Prefill for edit mode ─────────────────────────────────────────────────

  void _prefillExistingData() {
    final content = widget.existingContent!;

    _contentId = int.tryParse(content["id"].toString());
    final photo = content["guestPhoto"];
    _existingImageUrl =
        (photo != null && photo.toString().isNotEmpty) ? photo : null;

    final rooms = content["rooms"] as List?;
    if (rooms != null) {
      _selectedRooms = rooms
          .map<String>((r) => "Room ${r["room_number"]}")
          .toSet();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bool hasImage =
        _selectedImage != null || _existingImageUrl != null;
    final bool isAddContentEnabled =
        hasImage && _selectedRooms.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isEditMode ? 'Edit Photo' : 'Camera Content',
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const Text(
              'Upload and display content instantly',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
        elevation: 0,
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black),
        actions: _isEditMode
            ? []
            : [
                Container(
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F1FF),
                    borderRadius: BorderRadius.circular(50),
                  ),
                  child: IconButton(
                    icon: Icon(Icons.history_outlined, color: _accent),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const MyContentsPage(),
                        ),
                      );
                    },
                  ),
                ),
              ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _buildLandscapeTip(),
                    const SizedBox(height: 16),
                    _buildImageSection(),
                    const SizedBox(height: 20),
                    _buildRoomSection(),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ),

            // Fixed bottom buttons
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: _buildActionButtons(isAddContentEnabled),
            ),
          ],
        ),
      ),
    );
  }

  // ── Landscape tip banner ──────────────────────────────────────────────────

  Widget _buildLandscapeTip() {
    return GestureDetector(
      onTap: () => _showLandscapeInfoSheet(),
      child: Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _accent.withValues(alpha: 0.2)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.screen_rotation_outlined,
                  color: _accent, size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hold your phone sideways for the best shot',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: _accent),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Tap to learn more',
                    style: TextStyle(fontSize: 11, color: _accent),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: _accent, size: 18),
          ],
        ),
      ),
    );
  }

  void _showLandscapeInfoSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 20),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.screen_rotation_outlined,
                    color: _accent, size: 32),
              ),
              const SizedBox(height: 16),
              const Text(
                "Why Landscape?",
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary),
              ),
              const SizedBox(height: 10),
              const Text(
                "TV screens display in 16:9 widescreen format. Holding your phone "
                "horizontally ensures your photo fills the entire TV screen without "
                "black bars or cropping.",
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                    height: 1.6),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Got it",
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Image section ─────────────────────────────────────────────────────────

  Widget _buildImageSection() {
    final bool hasImage =
        _selectedImage != null || (_existingImageUrl?.isNotEmpty == true);

    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Tap to pick — only active when no image yet OR in edit mode
          GestureDetector(
            onTap: _isUploading
                ? null
                : (!hasImage || _isEditMode)
                    ? _showImagePicker
                    : null, // locked in upload mode once image is picked
            child: Stack(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: const Color(0xFFF0F1FF),
                      border: Border.all(
                          color: _accent.withValues(alpha: 0.3), width: 1.5),
                    ),
                    child: _selectedImage != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.file(_selectedImage!,
                                fit: BoxFit.cover),
                          )
                        : (_existingImageUrl?.isNotEmpty == true)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Image.network(
                                  _existingImageUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      _buildPlaceholder(),
                                ),
                              )
                            : _buildPlaceholder(),
                  ),
                ),

                // Uploading overlay
                if (_isUploading)
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.45),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2.5),
                            SizedBox(height: 10),
                            Text(
                              'Uploading…',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // ── CHANGED: Remove (×) button shown in BOTH upload and edit
                // mode whenever a local image is selected and not uploading.
                if (_selectedImage != null && !_isUploading)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: _removeImage,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                            color: Colors.black87,
                            shape: BoxShape.circle),
                        child: const Icon(Icons.close,
                            color: Colors.white, size: 16),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ── CHANGED: "Change Image" shown in BOTH upload and edit mode
          // when an image is present and not uploading.
          if (!_isUploading && hasImage) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _showImagePicker,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('Change Image'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: BorderSide(color: _accent.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Room section ──────────────────────────────────────────────────────────

  Widget _buildRoomSection() {
    if (_isLoadingRooms) {
      return Container(
        decoration: _cardDecoration(),
        padding: const EdgeInsets.all(24),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_roomsError != null) {
      return Container(
        decoration: _cardDecoration(),
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(_roomsError!,
                style: const TextStyle(color: AppColors.error)),
            const SizedBox(height: 10),
            ElevatedButton(
                onPressed: _fetchRooms, child: const Text("Retry")),
          ],
        ),
      );
    }

    if (_rooms.isEmpty) {
      return Container(
        decoration: _cardDecoration(),
        padding: const EdgeInsets.all(24),
        child: const Text("No rooms available",
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }

    return Container(
      decoration: _cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Select Rooms",
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary),
                ),
                TextButton(
                  onPressed: _toggleSelectAll,
                  child: Text(
                    _selectedRooms.length == _rooms.length
                        ? "Deselect All"
                        : "Select All",
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 2.4,
              children: _rooms.map((room) {
                final roomLabel = "Room ${room["roomNumber"]}";
                final selected = _selectedRooms.contains(roomLabel);

                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (selected) {
                        _selectedRooms.remove(roomLabel);
                      } else {
                        _selectedRooms.add(roomLabel);
                      }
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected ? _accent : const Color(0xFFF0F1FF),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: selected
                              ? _accent
                              : _accent.withValues(alpha: 0.2)),
                    ),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (selected)
                            const Icon(Icons.check_circle,
                                size: 16, color: Colors.white),
                          if (selected) const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              roomLabel,
                              style: TextStyle(
                                color:
                                    selected ? Colors.white : _accent,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Action buttons ────────────────────────────────────────────────────────

  Widget _buildActionButtons(bool enabled) {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  enabled ? _accent : Colors.grey.shade300,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed:
                (enabled && !_isUploading) ? _uploadContent : null,
            child: _isUploading
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                      SizedBox(width: 10),
                      Text('Uploading…',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                    ],
                  )
                : Text(
                    _isEditMode ? "Update Photo" : "Upload Photo",
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
          ),
        ),

        // Cancel only shown in edit mode — upload mode has no cancel
        if (_isEditMode) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _isUploading ? null : () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
          ),
        ],
      ],
    );
  }

  // ── Shared decorators ─────────────────────────────────────────────────────

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    );
  }

  Widget _buildPlaceholder() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.camera_alt_outlined,
              size: 32, color: _accent),
        ),
        const SizedBox(height: 12),
        const Text(
          'Tap to add a guest photo',
          style:
              TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        const Text(
          'Best taken in landscape',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }
}