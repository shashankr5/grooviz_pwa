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

class CameraContentPage extends StatefulWidget {
  final Map<String, dynamic>? existingContent;

  const CameraContentPage({super.key, this.existingContent});

  @override
  State<CameraContentPage> createState() => _CameraContentPageState();
}

class _CameraContentPageState extends State<CameraContentPage> {
  final ImagePicker _picker = ImagePicker();
  File? _selectedImage;
  int _timerSeconds = 5;
  DateTime? _startDate;
  int _startHour = 10;
  int _startMinute = 0;
  DateTime? _endDate;
  int _endHour = 10;
  int _endMinute = 0;
  Set<String> _selectedRooms = {};

  bool get _isEditMode => widget.existingContent != null;
  String? _existingImageUrl;
  int? _contentId;

  final TextEditingController _titleController = TextEditingController();
  String _contentTitle = "";

  final TextEditingController _timerController =
      TextEditingController(text: "5");

  final RoomsService _roomsService = RoomsService();

  List<Map<String, dynamic>> _rooms = [];
  bool _isLoadingRooms = true;
  String? _roomsError;

  bool _isUploading = false;

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

  @override
  void initState() {
    super.initState();
    _initializeDates();
    _fetchRooms();

    if (_isEditMode) {
      _prefillExistingData();
    }
  }

  void _initializeDates() {
    final now = DateTime.now();
    _startDate = now;
    _startHour = now.hour;
    _startMinute = now.minute;
    _endDate = now;
    _endHour = now.hour;
    _endMinute = now.minute;
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedRooms.length == _rooms.length) {
        _selectedRooms.clear();
      } else {
        _selectedRooms = _rooms.map((r) => "Room ${r["roomNumber"]}").toSet();
      }
    });
  }

  void _resetForm() {
    setState(() {
      _selectedImage = null;
      _existingImageUrl = null;
      _selectedRooms.clear();
      _timerSeconds = 5;
      _timerController.text = "5";
      _titleController.clear();
      _contentTitle = "";
      _initializeDates();
    });
  }

  DateTime _buildDateTime(DateTime? date, int hour, int minute) {
    final d = date ?? DateTime.now();
    return DateTime(d.year, d.month, d.day, hour, minute);
  }

  bool _validateDateTimes() {
    final now = DateTime.now();
    final startDateTime = _buildDateTime(_startDate, _startHour, _startMinute);
    final endDateTime = _buildDateTime(_endDate, _endHour, _endMinute);

    if (startDateTime.isBefore(now)) {
      _showError("Start time is in the past.");
      return false;
    }

    if (endDateTime.isBefore(now)) {
      _showError("End time is in the past.");
      return false;
    }

    if (!endDateTime.isAfter(startDateTime)) {
      _showError("End time must be after start time.");
      return false;
    }

    return true;
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
      setState(() {
        _rooms = List<Map<String, dynamic>>.from(rooms);
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

  // ─────────────────────────────────────────────────────────────────────────
  // HIGH-QUALITY IMAGE PROCESSING FOR 1920×1080 TV OUTPUT
  // ─────────────────────────────────────────────────────────────────────────

  /// Letterbox / pillarbox the source image onto a 1920×1080 black canvas.
  /// This preserves 100 % of the image (no cropping) for both landscape and
  /// portrait sources, while guaranteeing the exact resolution the TV needs.
  img.Image _fitTo1920x1080(img.Image src) {
    const int targetW = 1920;
    const int targetH = 1080;

    // Scale so the image fits entirely within 1920×1080 (no cropping)
    final double scaleW = targetW / src.width;
    final double scaleH = targetH / src.height;
    final double scale = scaleW < scaleH ? scaleW : scaleH;

    final int scaledW = (src.width * scale).round();
    final int scaledH = (src.height * scale).round();

    // High-quality cubic resize
    final img.Image resized = img.copyResize(
      src,
      width: scaledW,
      height: scaledH,
      interpolation: img.Interpolation.cubic, // best quality for upscaling
    );

    // Black 1920×1080 canvas
    final img.Image canvas = img.Image(
      width: targetW,
      height: targetH,
      numChannels: 3,
    );
    img.fill(canvas, color: img.ColorRgb8(0, 0, 0));

    // Center the resized image on the canvas
    final int dx = ((targetW - scaledW) / 2).round();
    final int dy = ((targetH - scaledH) / 2).round();
    img.compositeImage(canvas, resized, dstX: dx, dstY: dy);

    return canvas;
  }

  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _uploadContent() async {
    if (_isUploading) return;

    setState(() => _isUploading = true);

    if (!_validateDateTimes()) {
      setState(() => _isUploading = false);
      return;
    }

    if (_contentTitle.trim().isEmpty) {
      _showError("Please enter a content title");
      setState(() => _isUploading = false);
      return;
    }

    final deviceIds = _getSelectedDeviceIds();

    if (deviceIds.isEmpty) {
      _showError("No devices found for selected rooms");
      setState(() => _isUploading = false);
      return;
    }

    try {
      String finalUrl = _existingImageUrl ?? "";

      // Upload new image ONLY if user selected one
      if (_selectedImage != null) {
        final originalBytes = await _selectedImage!.readAsBytes();

        // Decode image
        final img.Image? decoded = img.decodeImage(originalBytes);
        if (decoded == null) throw Exception("Invalid image – could not decode");

        // ── STEP 1: Fix EXIF / orientation (critical for phone portrait photos) ──
        final img.Image oriented = img.bakeOrientation(decoded);

        // ── STEP 2: Letterbox to exact 1920×1080 with cubic interpolation ────────
        //    Works perfectly for BOTH landscape AND portrait source images.
        final img.Image tv = _fitTo1920x1080(oriented);

        // ── STEP 3: Encode as PNG (lossless – zero compression artefacts on TV) ──
        final List<int> outputBytes = img.encodePng(tv);

        // ── STEP 4: Build base64 payload ─────────────────────────────────────────
        final String base64Image =
            "data:image/png;base64,${base64Encode(outputBytes)}";

        final String enterpriseId =
            (await UserSessionHelper.getEnterpriseId())?.toString() ?? "";

        final UploadService uploadService = UploadService();

        final Map<String, dynamic> uploadResult =
            await uploadService.uploadBase64File(
          base64: base64Image,
          fileName: "content_${DateTime.now().millisecondsSinceEpoch}.png",
          contentType: "IMAGE",
          enterpriseId: enterpriseId,
        );

        if (!uploadResult["success"]) {
          throw Exception(uploadResult["message"]);
        }

        finalUrl = uploadResult["url"];
      }

      final DateTime startDateTime =
          _buildDateTime(_startDate, _startHour, _startMinute);
      final DateTime endDateTime =
          _buildDateTime(_endDate, _endHour, _endMinute);

      Map result;

      if (_isEditMode) {
        result = await _roomsService.updateContent(
          contentId: _contentId!,
          title: _contentTitle,
          filePath: finalUrl,
          startTime: startDateTime,
          endTime: endDateTime,
          displayTimer: _timerSeconds,
          deviceIds: deviceIds,
        );
      } else {
        result = await _roomsService.uploadImageContent(
          title: _contentTitle,
          filePath: finalUrl,
          startTime: startDateTime,
          endTime: endDateTime,
          displayTimer: _timerSeconds,
          deviceIds: deviceIds,
        );
      }

      if (!mounted) return;

      if (result["success"]) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result["message"]),
            backgroundColor: Colors.green,
          ),
        );

        _resetForm();

        if (_isEditMode) {
          Navigator.pop(context, true);
        } else {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const MyContentsPage()),
          );
        }
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
              _bottomSheetTile(
                  Icons.photo_library, "Gallery", Colors.deepPurple, () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              }),
              _bottomSheetTile(Icons.camera_alt, "Camera", Colors.black, () {
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
    _existingImageUrl = content["filePath"];

    _contentTitle = content["title"] ?? "";
    _titleController.text = _contentTitle;

    _timerSeconds = content["displayTimer"] ?? 5;
    _timerController.text = _timerSeconds.toString();

    final start = DateTime.tryParse(content["startTime"] ?? "");
    final end = DateTime.tryParse(content["endTime"] ?? "");

    if (start != null) {
      _startDate = start;
      _startHour = start.hour;
      _startMinute = start.minute;
    }

    if (end != null) {
      _endDate = end;
      _endHour = end.hour;
      _endMinute = end.minute;
    }

    final rooms = content["rooms"] as List?;
    if (rooms != null) {
      _selectedRooms =
          rooms.map<String>((r) => "Room ${r["room_number"]}").toSet();
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
  }

  Widget _bottomSheetTile(
      IconData icon, String title, Color color, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: color),
      title:
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }

  Future<void> _selectStartDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() => _startDate = picked);
    }
  }

  Future<void> _selectEndDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() => _endDate = picked);
    }
  }

  @override
  void dispose() {
    _timerController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isAddContentEnabled =
        (_selectedImage != null || _existingImageUrl != null) &&
            _selectedRooms.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text(
          'Camera Content',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        elevation: 1,
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black),
        actions: _isEditMode
            ? []
            : [
                IconButton(
                  icon: const Icon(Icons.history_outlined, color: Colors.black87),
                  tooltip: 'My Contents',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const MyContentsPage()),
                    );
                  },
                ),
                const SizedBox(width: 8),
              ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _buildImageSection(),
              const SizedBox(height: 20),
              _buildTitleSection(),
              const SizedBox(height: 20),
              _buildRoomSection(),
              const SizedBox(height: 20),
              _buildDateSection(
                  "Start Date & Time", _startDate, _selectStartDate, true),
              const SizedBox(height: 20),
              _buildDateSection(
                  "End Date & Time", _endDate, _selectEndDate, false),
              const SizedBox(height: 20),
              _buildTimerSection(),
              const SizedBox(height: 30),
              _buildActionButtons(isAddContentEnabled),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageSection() {
    return Container(
      decoration: _cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: GestureDetector(
                onTap: _selectedImage == null ? _showImagePicker : null,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: Colors.grey[200],
                  ),
                  child: _selectedImage != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.file(_selectedImage!, fit: BoxFit.cover),
                        )
                      : _existingImageUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.network(_existingImageUrl!,
                                  fit: BoxFit.cover),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                Icon(Icons.camera_alt,
                                    size: 48, color: Colors.grey),
                                SizedBox(height: 12),
                                Text(
                                  'Tap to add content image',
                                  style: TextStyle(
                                      fontSize: 14, color: Colors.grey),
                                ),
                              ],
                            ),
                ),
              ),
            ),
            if (_selectedImage != null)
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: _removeImage,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, color: Colors.white, size: 18),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleSection() {
    return Container(
      decoration: _cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Content Title",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _titleController,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: "Enter content title",
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (value) {
                setState(() => _contentTitle = value.trim());
              },
            ),
          ],
        ),
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
            Text(_roomsError!, style: const TextStyle(color: Colors.red)),
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
        child: const Text("No rooms available"),
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
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: _toggleSelectAll,
                  child: Text(
                    _selectedRooms.length == _rooms.length
                        ? "Deselect All"
                        : "Select All",
                    style: const TextStyle(
                        color: Colors.black, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _rooms.length,
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 3,
              ),
              itemBuilder: (context, index) {
                final room = _rooms[index];
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
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? Colors.amber[700]
                          : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      roomLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color:
                            selected ? Colors.white : Colors.black87,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateSection(
      String title, DateTime? date, VoidCallback onTap, bool isStart) {
    return Container(
      decoration: _cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today,
                        size: 18, color: Colors.grey),
                    const SizedBox(width: 12),
                    Text(
                      date != null
                          ? "${date.day}/${date.month}/${date.year}"
                          : "Select Date",
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildMinimalTimeSelector(
              hour: isStart ? _startHour : _endHour,
              minute: isStart ? _startMinute : _endMinute,
              onHourChanged: (v) => setState(
                  () => isStart ? _startHour = v : _endHour = v),
              onMinuteChanged: (v) => setState(
                  () => isStart ? _startMinute = v : _endMinute = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimerSection() {
    return Container(
      decoration: _cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Display Timer",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Enter how many seconds the content should be displayed",
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _timerController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                hintText: "Enter seconds",
                suffixText: "sec",
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (value) {
                if (value.isNotEmpty) {
                  final int? parsed = int.tryParse(value);
                  if (parsed != null && parsed >= 1 && parsed <= 60) {
                    setState(() => _timerSeconds = parsed);
                  }
                }
              },
            ),
            const SizedBox(height: 8),
            const Text(
              "Allowed range: 1–60 seconds",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(bool enabled) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  enabled ? Colors.black : Colors.grey.shade400,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
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
                    _isEditMode ? "Update Content" : "Add Content",
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.black, width: 1.2),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: () {
              setState(() {
                _selectedImage = null;
                _selectedRooms.clear();
                _timerSeconds = 5;
                _timerController.text = "5";
                _initializeDates();
              });
            },
            child: const Text(
              "Cancel",
              style:
                  TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
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

  Widget _buildMinimalTimeSelector({
    required int hour,
    required int minute,
    required ValueChanged<int> onHourChanged,
    required ValueChanged<int> onMinuteChanged,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        NumberPicker(
          value: hour,
          minValue: 0,
          maxValue: 23,
          itemHeight: 40,
          selectedTextStyle:
              const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          onChanged: onHourChanged,
        ),
        const Text(":",
            style:
                TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        NumberPicker(
          value: minute,
          minValue: 0,
          maxValue: 59,
          itemHeight: 40,
          selectedTextStyle:
              const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          onChanged: onMinuteChanged,
        ),
      ],
    );
  }
}