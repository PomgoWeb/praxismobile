class WebViewAuthNavigationGuard {
  const WebViewAuthNavigationGuard._();

  static bool shouldCancelAutomaticLogoutNavigation({
    required Uri uri,
    required bool usesCookiePersistenceWorkaround,
    required bool logoutNavigationAllowed,
    required bool isUserInitiated,
  }) {
    if (!usesCookiePersistenceWorkaround) return false;
    if (!isLogoutUrl(uri)) return false;
    if (logoutNavigationAllowed) return false;
    return !isUserInitiated;
  }

  static bool shouldCancelAuthenticatedLoginResolverNavigation({
    required Uri uri,
    required bool usesCookiePersistenceWorkaround,
    required bool hasAuthenticatedSession,
    required bool isUserInitiated,
  }) {
    if (!usesCookiePersistenceWorkaround) return false;
    if (!hasAuthenticatedSession) return false;
    if (!isLoginResolverUrl(uri)) return false;
    return !isUserInitiated;
  }

  static bool isLoginResolverUrl(Uri uri) {
    return uri.queryParameters.containsKey('pab_ulule_login_resolve');
  }

  static bool isLogoutUrl(Uri? uri) {
    if (uri == null) return false;
    final String value = uri.toString().toLowerCase();
    return value.contains('logout') ||
        value.contains('logged_out') ||
        value.contains('swpm_logged_out') ||
        value.contains('log-out') ||
        value.contains('deconnexion') ||
        value.contains('d%c3%a9connexion') ||
        value.contains('wp-login.php?action=logout');
  }
}
