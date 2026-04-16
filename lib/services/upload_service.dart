import 'dart:convert';
import 'package:dio/dio.dart';
import '../utils/user_session_helper.dart';
import '../constants/api_constants.dart';

class UploadService {
  final Dio _dio = Dio();

  /// Convert S3 URL → CDN URL
  String _convertS3ToCdnUrl(String url) {
    final regex = RegExp(
      r'https:\/\/digisignage-uploads\.s3\.[a-z0-9-]+\.amazonaws\.com',
    );

    return url.replaceAll(regex, "https://cdn.tekchant.com");
  }

  Future<Map<String, dynamic>> uploadBase64File({
    required String base64,
    required String fileName,
    required String contentType, // IMAGE / VIDEO
    required String enterpriseId,
    int isContentFile = 1,
  }) async {
    try {
      final payload = {
        "stage": "dev",
        "ENTERPRISE_ID": enterpriseId,
        "CONTENT_TYPE": contentType,
        "FILE_B64": base64,
        "FILE_NAME": fileName,
        "IS_CONTENT_FILE": isContentFile,
      };

      final response = await _dio.post(
        "https://api.mobiezy.in/php/s3_upload/index.php",
        data: jsonEncode(payload),
        options: Options(
            headers: {
            "Content-Type": "application/json",
            "Accept": "application/json",
            },
        ),
    );

      String? url;

      if (response.data["url"] != null) {
        url = response.data["url"];
      } else if (response.data["body"] != null) {
        final body = jsonDecode(response.data["body"]);
        url = body["url"] ?? body["filePath"];
      }
      if (url == null) {
        return {"success": false, "message": "No file URL returned"};
        }

        return {
        "success": true,
        "url": url, // original S3 URL
        };

    } catch (e) {
      return {"success": false, "message": e.toString()};
    }
  }
}