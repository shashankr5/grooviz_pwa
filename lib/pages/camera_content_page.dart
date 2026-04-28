import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:numberpicker/numberpicker.dart';
import 'package:image/image.dart' as img;

import 'my_contents_page.dart'; 
import '../services/rooms_service.dart';
import '../services/upload_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/app_colors.dart';

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
  bool _isPrefilled = false;
  
  final RoomsService _roomsService = RoomsService();

  List<Map<String, dynamic>> _rooms = [];
  bool _isLoadingRooms = true;
  String? _roomsError;

  bool _isUploading = false;

  static const Color _accent = Color(0xFF5C6BC0);

  List<int> _getSelectedDeviceIds() {
    final selectedRooms = _rooms.where((room) {
      final label = "Room ${room["roomNumber"]}";
      return _selectedRooms.contains(label);
      print("Rooms: $_rooms");
      print("Selected Rooms: $_selectedRooms");
    });

    return selectedRooms
        .expand((room) => room["devices"])
        .map<int>((d) => d["device_id"])
        .toSet()
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _fetchRooms();

    if (_isEditMode) {
      _prefillExistingData();
      _isPrefilled = true;
    }
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedRooms.length == _rooms.length) {
        _selectedRooms.clear();
      } else {
        _selectedRooms =
          _rooms.map((r) => "Room ${r["roomNumber"]}").toSet();
            }
    });
  }

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

      // ✅ FILTER ONLY OCCUPIED ROOMS
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking image: $e')),
        );
      }
    }
  }

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

  Future<void> _uploadContent() async {
    if (_isUploading) return;

    setState(() => _isUploading = true);

    final deviceIds = _getSelectedDeviceIds();
    print("Selected Device IDs: $deviceIds");

    if (deviceIds.isEmpty) {
      _showError("No devices found for selected rooms");
      setState(() => _isUploading = false);
      return;
    }

    if (_selectedImage == null && _existingImageUrl == null) {
      _showError("Please select an image");
      setState(() => _isUploading = false);
      return;
    }

    try {
      String finalUrl = _existingImageUrl ?? "";

      /// upload new image if selected
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

      /// 🔥 NEW API CALL
      final result = await _roomsService.updateGuestPhoto(
        filePath: finalUrl,
        deviceIds: deviceIds,
      );

      if (!mounted) return;

      if (result["success"]) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result["message"]),
            backgroundColor: AppColors.secondary,
          ),
        );

        _resetForm();
      } else {
        throw Exception(result["message"]);
      }
    } catch (e) {
      _showError("Upload failed: $e");
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _removeImage() {
    setState(() {
      _selectedImage = null;
    });
  }

  void _showImagePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _bottomSheetTile(Icons.photo_library, "Gallery", AppColors.primary,
                  () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              }),
              _bottomSheetTile(Icons.camera_alt, "Camera", AppColors.textPrimary, () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              }),
            ],
          ),
        ),
      ),
    );
  }

  void _prefillExistingData() {
    final content = widget.existingContent!;

    _contentId = int.tryParse(content["id"].toString());
    final photo = content["guestPhoto"];
    _existingImageUrl = (photo != null && photo.toString().isNotEmpty) ? photo : null;

    /// preselect rooms
    final rooms = content["rooms"] as List?;
    if (rooms != null) {
      _selectedRooms = rooms
          .map<String>((r) => "Room ${r["room_number"]}")
          .toSet();
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppColors.error,
        ),
      );
  }

  Widget _bottomSheetTile(
      IconData icon, String title, Color color, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isAddContentEnabled =
        (_selectedImage != null || _existingImageUrl != null) &&
        _selectedRooms.isNotEmpty;

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

            /// SCROLLABLE CONTENT
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _buildImageSection(),
                    const SizedBox(height: 20),

                    _buildRoomSection(),
                    const SizedBox(height: 20),

                    const SizedBox(height: 80), // space for bottom buttons
                  ],
                ),
              ),
            ),

            /// 🔥 FIXED BOTTOM BUTTONS
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
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

  Widget _buildImageSection() {
    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          GestureDetector(
            onTap: _showImagePicker,
            child: Stack(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: const Color(0xFFF0F1FF),
                      border: Border.all(
                        color: _accent.withOpacity(0.3),
                        width: 1.5,
                      ),
                    ),
                    child: _selectedImage != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.file(_selectedImage!, fit: BoxFit.cover),
                          )
                        : (_existingImageUrl != null && _existingImageUrl!.isNotEmpty)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Image.network(
                                  _existingImageUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => _buildPlaceholder(),
                                ),
                              )
                            : _buildPlaceholder(),
                ),
                ),
                if (_selectedImage != null)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: _removeImage,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          color: Colors.black87,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close,
                            color: Colors.white, size: 16),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          if (_selectedImage != null ||
    (_existingImageUrl != null && _existingImageUrl!.isNotEmpty)) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _showImagePicker,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('Change Image'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: BorderSide(color: _accent.withOpacity(0.4)),
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
            Text(
              _roomsError!,
              style: const TextStyle(color: AppColors.error),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _fetchRooms,
              child: const Text("Retry"),
            )
          ],
        ),
      );
    }

    if (_rooms.isEmpty) {
      return Container(
        decoration: _cardDecoration(),
        padding: const EdgeInsets.all(24),
        child: const Text("No rooms available", style: TextStyle(color: AppColors.textSecondary)),
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
                )
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected ? _accent : const Color(0xFFF0F1FF),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected ? _accent : _accent.withOpacity(0.2),
                      ),
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
                                color: selected ? Colors.white : _accent,
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

  Widget _buildActionButtons(bool enabled) {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: enabled ? _accent : Colors.grey.shade300,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: (enabled && !_isUploading) ? _uploadContent : null,
            child: _isUploading
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    _isEditMode ? "Update Photo" : "Upload Photo",
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _resetForm,
            child: const Text("Cancel"),
          ),
        ),
      ],
    );
  }
  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.05),
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
            color: _accent.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.person_outline,
            size: 32,
            color: _accent,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'No image available',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}