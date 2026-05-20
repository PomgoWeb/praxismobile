import 'package:flutter_test/flutter_test.dart';
import 'package:praxis_media_app/config/app_config.dart';
import 'package:praxis_media_app/utils/url_utils.dart';

void main() {
  test('base url keeps trailing slash', () {
    expect(ensureTrailingSlash(kBaseUrl).endsWith('/'), isTrue);
  });

  test('buildUrl merges relative path', () {
    final Uri url = buildUrl(kBaseUrl, '/articles/');
    expect(url.toString(), 'https://praxismedia.fr/articles/');
  });
}
