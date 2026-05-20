import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../utils/url_utils.dart';
import 'app_logger.dart';

class WpApi {
  WpApi({required AppLogger logger}) : _logger = logger;

  final AppLogger _logger;

  Future<void> registerToken({
    required String token,
    required String platform,
    required String locale,
    required String appVersion,
  }) async {
    final String normalizedToken = token.replaceAll(RegExp(r'\s+'), '').trim();
    if (normalizedToken.isEmpty) return;

    final Uri endpoint = buildUrl(kBaseUrl, kRegisterEndpoint);
    try {
      final http.Response response = await http
          .post(
            endpoint,
            headers: <String, String>{
              'Content-Type': 'application/json',
              kRegisterTokenHeader: kRegisterTokenKey,
            },
            body: jsonEncode(<String, String>{
              'token': normalizedToken,
              'platform': platform,
              'locale': locale,
              'appVersion': appVersion,
            }),
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _logger.log(
          'push_register_error',
          details: <String, Object?>{
            'status': response.statusCode,
            'body': response.body,
          },
        );
      }
    } on Exception catch (error, stackTrace) {
      _logger.log('push_register_error', error: error, stackTrace: stackTrace);
    }
  }
}
