import 'package:flutter_test/flutter_test.dart';
import 'package:praxis_media_app/utils/webview_auth_navigation_guard.dart';

void main() {
  group('WebViewAuthNavigationGuard', () {
    test('cancels automatic SWPM logout redirects on iOS workaround path', () {
      final Uri uri = Uri.parse('https://praxismedia.fr/?swpm_logged_out=1%2F');

      expect(
        WebViewAuthNavigationGuard.shouldCancelAutomaticLogoutNavigation(
          uri: uri,
          usesCookiePersistenceWorkaround: true,
          logoutNavigationAllowed: false,
          isUserInitiated: false,
        ),
        isTrue,
      );
    });

    test('allows explicit user initiated logout', () {
      final Uri uri = Uri.parse('https://praxismedia.fr/?swpm_logged_out=1');

      expect(
        WebViewAuthNavigationGuard.shouldCancelAutomaticLogoutNavigation(
          uri: uri,
          usesCookiePersistenceWorkaround: true,
          logoutNavigationAllowed: false,
          isUserInitiated: true,
        ),
        isFalse,
      );
    });

    test(
      'allows logout after app explicitly marked logout navigation allowed',
      () {
        final Uri uri = Uri.parse('https://praxismedia.fr/?swpm_logged_out=1');

        expect(
          WebViewAuthNavigationGuard.shouldCancelAutomaticLogoutNavigation(
            uri: uri,
            usesCookiePersistenceWorkaround: true,
            logoutNavigationAllowed: true,
            isUserInitiated: false,
          ),
          isFalse,
        );
      },
    );

    test('cancels automatic login resolver while already authenticated', () {
      final Uri uri = Uri.parse(
        'https://praxismedia.fr/?pab_ulule_login_resolve=1',
      );

      expect(
        WebViewAuthNavigationGuard.shouldCancelAuthenticatedLoginResolverNavigation(
          uri: uri,
          usesCookiePersistenceWorkaround: true,
          hasAuthenticatedSession: true,
          isUserInitiated: false,
        ),
        isTrue,
      );
    });

    test(
      'does not cancel login resolver before authenticated state is known',
      () {
        final Uri uri = Uri.parse(
          'https://praxismedia.fr/?pab_ulule_login_resolve=1',
        );

        expect(
          WebViewAuthNavigationGuard.shouldCancelAuthenticatedLoginResolverNavigation(
            uri: uri,
            usesCookiePersistenceWorkaround: true,
            hasAuthenticatedSession: false,
            isUserInitiated: false,
          ),
          isFalse,
        );
      },
    );

    test('does not apply iOS workaround guards on non-iOS paths', () {
      final Uri logoutUri = Uri.parse(
        'https://praxismedia.fr/?swpm_logged_out=1%2F',
      );
      final Uri resolverUri = Uri.parse(
        'https://praxismedia.fr/?pab_ulule_login_resolve=1',
      );

      expect(
        WebViewAuthNavigationGuard.shouldCancelAutomaticLogoutNavigation(
          uri: logoutUri,
          usesCookiePersistenceWorkaround: false,
          logoutNavigationAllowed: false,
          isUserInitiated: false,
        ),
        isFalse,
      );
      expect(
        WebViewAuthNavigationGuard.shouldCancelAuthenticatedLoginResolverNavigation(
          uri: resolverUri,
          usesCookiePersistenceWorkaround: false,
          hasAuthenticatedSession: true,
          isUserInitiated: false,
        ),
        isFalse,
      );
    });
  });
}
