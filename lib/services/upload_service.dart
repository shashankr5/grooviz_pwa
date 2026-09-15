// upload_service.dart
import 'dart:convert';
import 'package:dio/dio.dart';
import '../utils/user_session_helper.dart';
import '../utils/error_handler.dart';
import '../constants/api_timeouts.dart';
import '../constants/app_config.dart';

class UploadService {
  final Dio _dio = Dio();

  /// Convert S3 URL → CDN URL for fast, cached delivery to TV devices.
  String _convertS3ToCdnUrl(String url) {
    final regex = RegExp(
      r'https:\/\/digisignage-uploads\.s3\.[a-z0-9-]+\.amazonaws\.com',
    );
    return url.replaceAll(regex, "https://cdn.tekchant.com");
  }

  /// Uploads a base64-encoded file (IMAGE or VIDEO) to S3 via the proxy API
  /// and returns the CDN URL so TV devices load it with maximum speed.
  ///
  /// [base64]       – full data-URI string, e.g. "data:image/png;base64,..."
  /// [fileName]     – suggested file name, e.g. "content_1234567890.png"
  /// [contentType]  – "IMAGE" or "VIDEO"
  /// [enterpriseId] – tenant identifier from [UserSessionHelper]
  /// [isContentFile]– 1 = content file (default), 0 = other asset
  
  Future<Map<String, dynamic>> uploadBase64File({
    required String base64,
    required String fileName,
    required String contentType,
    required String enterpriseId,
    int isContentFile = 1,
  }) async {
    try {
      final Map<String, dynamic> payload = {
        "stage": AppConfig.stage,
        "ENTERPRISE_ID": enterpriseId,
        "CONTENT_TYPE": contentType,
        "FILE_B64": base64,
        "FILE_NAME": fileName,
        "IS_CONTENT_FILE": isContentFile,
      };

      final Response response = await _dio.post(
        "https://internal.winpuducherry.com/php/s3_upload/index1.php",
        data: jsonEncode(payload),
        options: Options(
          headers: {
            "Content-Type": "application/json",
            "Accept": "application/json",
          },
          // Give large PNG uploads enough time to complete
          sendTimeout: ApiTimeouts.uploadSendTimeout,
          receiveTimeout: ApiTimeouts.uploadReceiveTimeout,
        ),
      );

      // ── Parse URL from response ───────────────────────────────────────────
      // The API can return the URL either at the top level or nested in "body".
      String? rawUrl;

      if (response.data is Map) {
        rawUrl = response.data["url"] as String?;

        if (rawUrl == null && response.data["body"] != null) {
          final dynamic bodyRaw = response.data["body"];
          final Map<String, dynamic> body = bodyRaw is String
              ? jsonDecode(bodyRaw) as Map<String, dynamic>
              : bodyRaw as Map<String, dynamic>;
          rawUrl = (body["url"] ?? body["filePath"]) as String?;
        }
      }

      if (rawUrl == null || rawUrl.isEmpty) {
        return {"success": false, "message": "No file URL returned from server"};
      }

      // ── Convert S3 → CDN URL before returning ────────────────────────────
      final String cdnUrl = _convertS3ToCdnUrl(rawUrl);

      return {
        "success": true,
        "url": cdnUrl, // CDN URL ready for TV playback
      };
    } on DioException catch (e) {
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    } catch (e) {
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }
}