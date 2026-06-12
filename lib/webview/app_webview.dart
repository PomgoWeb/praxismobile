import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/app_state.dart';
import '../services/app_logger.dart';
import '../services/webview_cookie_store.dart';
import '../ui/startup_splash.dart';
import '../utils/url_utils.dart';

class AppWebView extends StatefulWidget {
  const AppWebView({super.key});

  @override
  State<AppWebView> createState() => _AppWebViewState();
}

class _AppWebViewState extends State<AppWebView>
    with AutomaticKeepAliveClientMixin<AppWebView>, WidgetsBindingObserver {
  InAppWebViewController? _controller;
  late final WebViewCookieStore _cookieStore;
  int _lastConsumedRequestId = -1;
  bool _isLoading = true;
  bool _showStartupSplash = true;
  String? _lastError;
  Timer? _startupSplashTimer;
  bool _loggedFirstBuild = false;
  bool _preloadedActionPages = false;
  bool _paymentFlowNavigationAllowed = false;
  bool _cookiesRestored = false;
  bool _authCookieRecoveryAttempted = false;

  @override
  bool get wantKeepAlive => true;

  bool get _usesCookiePersistenceWorkaround {
    return defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    _cookieStore = WebViewCookieStore(logger: context.read<AppLogger>());
    if (_usesCookiePersistenceWorkaround) {
      WidgetsBinding.instance.addObserver(this);
      unawaited(_restoreCookiesBeforeFirstLoad());
    } else {
      _cookiesRestored = true;
    }
    _startupSplashTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      context.read<AppLogger>().log('startup_splash_timeout');
      setState(() {
        _showStartupSplash = false;
      });
    });
  }

  @override
  void dispose() {
    if (_usesCookiePersistenceWorkaround) {
      WidgetsBinding.instance.removeObserver(this);
      unawaited(_cookieStore.persist());
    }
    _startupSplashTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_usesCookiePersistenceWorkaround) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_cookieStore.persist());
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final AppState appState = context.watch<AppState>();
    if (!_loggedFirstBuild) {
      _loggedFirstBuild = true;
      context.read<AppLogger>().log('webview_widget_first_build');
    }

    _consumePendingNavigation(appState);

    if (!_cookiesRestored) {
      return const StartupSplash();
    }

    return Stack(
      children: <Widget>[
        InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri.uri(appState.buildPathUrl(appState.currentPath)),
          ),
          initialSettings: InAppWebViewSettings(
            userAgent: 'Mozilla/5.0 $kAppUserAgentTag',
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            incognito: false,
            cacheEnabled: true,
            sharedCookiesEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            supportZoom: false,
            builtInZoomControls: false,
            displayZoomControls: false,
            ignoresViewportScaleLimits: false,
          ),
          onWebViewCreated: (InAppWebViewController controller) {
            _controller = controller;
            appState.markWebViewReady();
            context.read<AppLogger>().log('webview_created');
          },
          onLoadStart: (InAppWebViewController controller, WebUri? uri) {
            setState(() {
              _showStartupSplash = false;
              _isLoading = true;
              _lastError = null;
            });
            _startupSplashTimer?.cancel();
            context.read<AppLogger>().log(
              'webview_load_start',
              details: <String, Object?>{'url': uri?.toString() ?? ''},
            );
            unawaited(_injectAppCssClasses(controller));
          },
          onLoadStop: (InAppWebViewController controller, WebUri? uri) {
            setState(() {
              _showStartupSplash = false;
              _isLoading = false;
              _lastError = null;
            });
            _startupSplashTimer?.cancel();
            appState.markLoadedUrl(uri?.toString());
            unawaited(_injectAppCssClasses(controller));
            unawaited(_preloadActionPages(controller, appState));
            if (_usesCookiePersistenceWorkaround) {
              unawaited(_persistCookiesAfterLoad(controller, uri));
            }
            unawaited(_logCookieState());
            unawaited(_writeHtmlSnapshot(controller, uri));
            context.read<AppLogger>().log(
              'webview_load_stop',
              details: <String, Object?>{'url': uri?.toString() ?? ''},
            );
          },
          onReceivedError:
              (
                InAppWebViewController controller,
                WebResourceRequest request,
                WebResourceError error,
              ) {
                setState(() {
                  _showStartupSplash = false;
                  _isLoading = false;
                  _lastError = error.description;
                });
                _startupSplashTimer?.cancel();
                context.read<AppLogger>().log(
                  'webview_load_error',
                  details: <String, Object?>{
                    'code': error.type.toString(),
                    'description': error.description,
                  },
                );
              },
          shouldOverrideUrlLoading:
              (
                InAppWebViewController controller,
                NavigationAction navigationAction,
              ) async {
                final Uri? rawUri = navigationAction.request.url?.uriValue;
                if (rawUri == null) return NavigationActionPolicy.ALLOW;

                final Uri baseUri = Uri.parse(kBaseUrl);
                final bool external = !isSameDomainOrSubdomain(baseUri, rawUri);
                if (external) {
                  if (!navigationAction.isForMainFrame) {
                    context.read<AppLogger>().log(
                      'webview_external_subframe_allowed',
                      details: <String, Object?>{'url': rawUri.toString()},
                    );
                    return NavigationActionPolicy.ALLOW;
                  }

                  final bool isUserNavigation =
                      navigationAction.hasGesture == true ||
                      navigationAction.navigationType ==
                          NavigationType.LINK_ACTIVATED;
                  final bool isPaymentRedirect =
                      _isStripeCheckoutNavigation(rawUri) ||
                      _paymentFlowNavigationAllowed;
                  context.read<AppLogger>().log(
                    'webview_external_navigation',
                    details: <String, Object?>{
                      'url': rawUri.toString(),
                      'mainFrame': navigationAction.isForMainFrame,
                      'hasGesture': navigationAction.hasGesture,
                      'navigationType':
                          navigationAction.navigationType?.toString() ?? '',
                      'paymentRedirect': isPaymentRedirect,
                      'allowed': isUserNavigation || isPaymentRedirect,
                    },
                  );
                  if (isPaymentRedirect) {
                    _paymentFlowNavigationAllowed = true;
                    return NavigationActionPolicy.ALLOW;
                  }
                  if (!isUserNavigation) {
                    return NavigationActionPolicy.CANCEL;
                  }
                  await launchUrl(rawUri, mode: LaunchMode.externalApplication);
                  return NavigationActionPolicy.CANCEL;
                }
                if (_paymentFlowNavigationAllowed) {
                  _paymentFlowNavigationAllowed = false;
                  context.read<AppLogger>().log(
                    'webview_payment_flow_returned_to_app_domain',
                    details: <String, Object?>{'url': rawUri.toString()},
                  );
                }
                return NavigationActionPolicy.ALLOW;
              },
        ),
        if (_showStartupSplash)
          const Positioned.fill(child: StartupSplash())
        else if (_isLoading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_lastError != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Material(
              color: Colors.red.shade700,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Erreur de chargement: $_lastError',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _consumePendingNavigation(AppState appState) {
    if (_controller == null) return;
    if (appState.requestedUrl == null) return;
    if (_lastConsumedRequestId == appState.navRequestId) return;

    _lastConsumedRequestId = appState.navRequestId;
    final String targetUrl = appState.requestedUrl!;
    context.read<AppLogger>().log(
      'webview_load_url_requested',
      details: <String, Object?>{'url': targetUrl},
    );
    unawaited(
      _controller!.loadUrl(urlRequest: URLRequest(url: WebUri(targetUrl))),
    );
    appState.consumeNavigation(appState.navRequestId);
  }

  Future<void> _restoreCookiesBeforeFirstLoad() async {
    final AppLogger logger = context.read<AppLogger>();
    await _cookieStore.restore().timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        logger.log('webview_cookie_restore_timeout');
      },
    );
    if (!mounted) return;
    setState(() {
      _cookiesRestored = true;
    });
  }

  Future<void> _persistCookiesAfterLoad(
    InAppWebViewController controller,
    WebUri? uri,
  ) async {
    final AppLogger logger = context.read<AppLogger>();
    final bool allowsAuthCookieRemoval = _isLogoutUrl(uri?.uriValue);
    final WebViewCookiePersistResult result = await _cookieStore.persist(
      allowAuthCookieRemoval: allowsAuthCookieRemoval,
    );

    if (!mounted) return;
    if (allowsAuthCookieRemoval) return;
    if (!result.preservedAuthCookies) return;
    if (_authCookieRecoveryAttempted) return;

    _authCookieRecoveryAttempted = true;
    logger.log(
      'webview_cookie_auth_recovery_reload',
      details: <String, Object?>{
        'url': uri?.toString() ?? '',
        'preservedAuthCookieCount': result.preservedAuthCookieCount,
      },
    );

    await _cookieStore.restore();
    await controller.reload();
  }

  Future<void> _preloadActionPages(
    InAppWebViewController controller,
    AppState appState,
  ) async {
    if (_preloadedActionPages || appState.isOffline) return;
    _preloadedActionPages = true;

    final List<String> urls = kMenuDestinations
        .map((MenuDestination destination) {
          return appState.buildPathUrl(destination.path).toString();
        })
        .toSet()
        .toList(growable: false);

    context.read<AppLogger>().log(
      'webview_preload_action_pages_start',
      details: <String, Object?>{'count': urls.length},
    );

    try {
      await controller.evaluateJavascript(
        source:
            '''
          (function(urls) {
            if (!Array.isArray(urls) || !urls.length) return;
            window.rsappPreloadedActionPages = window.rsappPreloadedActionPages || {};

            urls.forEach(function(url) {
              if (!url || window.rsappPreloadedActionPages[url]) return;
              window.rsappPreloadedActionPages[url] = true;

              try {
                var link = document.createElement('link');
                link.rel = 'prefetch';
                link.href = url;
                link.as = 'document';
                (document.head || document.documentElement).appendChild(link);
              } catch (_) {}
            });
          })(${jsonEncode(urls)});
        ''',
      );
      if (!mounted) return;
      context.read<AppLogger>().log(
        'webview_preload_action_pages_done',
        details: <String, Object?>{'count': urls.length},
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      context.read<AppLogger>().logError(
        'webview_preload_action_pages_error',
        error,
        stackTrace,
      );
    }
  }

  bool _isStripeCheckoutNavigation(Uri uri) {
    final String host = uri.host.toLowerCase();
    return uri.scheme == 'https' && host == 'checkout.stripe.com';
  }

  bool _isLogoutUrl(Uri? uri) {
    if (uri == null) return false;
    final String value = uri.toString().toLowerCase();
    return value.contains('logout') ||
        value.contains('log-out') ||
        value.contains('deconnexion') ||
        value.contains('d%c3%a9connexion') ||
        value.contains('wp-login.php?action=logout');
  }

  Future<void> _logCookieState() async {
    final AppLogger logger = context.read<AppLogger>();
    try {
      final List<Cookie> cookies = await CookieManager.instance().getCookies(
        url: WebUri(kBaseUrl),
      );
      if (!mounted) return;

      final int wordpressCookieCount = cookies.where((Cookie cookie) {
        return cookie.name.toLowerCase().startsWith('wordpress_') ||
            cookie.name.toLowerCase().startsWith('wp-');
      }).length;
      final int sessionOnlyCount = cookies.where((Cookie cookie) {
        return cookie.isSessionOnly == true;
      }).length;

      logger.log(
        'webview_cookie_state',
        details: <String, Object?>{
          'count': cookies.length,
          'wordpressCount': wordpressCookieCount,
          'sessionOnlyCount': sessionOnlyCount,
          'persistentCount': cookies.length - sessionOnlyCount,
        },
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      logger.logError('webview_cookie_state_error', error, stackTrace);
    }
  }

  Future<void> _writeHtmlSnapshot(
    InAppWebViewController controller,
    WebUri? uri,
  ) async {
    final AppLogger logger = context.read<AppLogger>();
    try {
      final Object? result = await controller.evaluateJavascript(
        source: '''
          (function() {
            function outerHtml(selector) {
              var element = document.querySelector(selector);
              return element ? element.outerHTML : null;
            }
            function rect(selector) {
              var element = document.querySelector(selector);
              if (!element) return null;
              var box = element.getBoundingClientRect();
              var style = window.getComputedStyle(element);
              return {
                left: Math.round(box.left),
                right: Math.round(box.right),
                top: Math.round(box.top),
                width: Math.round(box.width),
                height: Math.round(box.height),
                display: style.display,
                visibility: style.visibility,
                position: style.position,
                flex: style.flex,
                flexBasis: style.flexBasis,
                marginLeft: style.marginLeft,
                marginRight: style.marginRight,
                transform: style.transform
              };
            }

            var subscribe = document.getElementById('subscribe-header-mobile');
            var login = document.getElementById('login-header');
            var headerActions = subscribe ? subscribe.parentElement : null;
            var subscribeRect = subscribe ? subscribe.getBoundingClientRect() : null;
            var loginRect = login ? login.getBoundingClientRect() : null;

            return {
              url: String(window.location.href || ''),
              title: String(document.title || ''),
              html: document.documentElement ? document.documentElement.outerHTML : '',
              diagnostics: {
                htmlClasses: document.documentElement ? document.documentElement.className : '',
                bodyClasses: document.body ? document.body.className : '',
                headerActionsClasses: headerActions ? headerActions.className : null,
                visibleGap: subscribeRect && loginRect ? Math.round(loginRect.left - subscribeRect.right) : null,
                subscribe: rect('#subscribe-header-mobile'),
                login: rect('#login-header'),
                toggle: rect('.elementor-widget-foxiz-collapse-toggle'),
                mobileToggle: rect('.mobile-toggle-wrap'),
                headerActionsHtml: headerActions ? headerActions.outerHTML : null,
                subscribeHtml: outerHtml('#subscribe-header-mobile'),
                loginHtml: outerHtml('#login-header'),
                toggleHtml: outerHtml('.elementor-widget-foxiz-collapse-toggle'),
                mobileToggleHtml: outerHtml('.mobile-toggle-wrap')
              }
            };
          })();
        ''',
      );
      if (!mounted || result is! Map) return;

      final String html = result['html']?.toString() ?? '';
      final Object? diagnostics = result['diagnostics'];
      final String snapshot = const JsonEncoder.withIndent('  ')
          .convert(<String, Object?>{
            'capturedAt': DateTime.now().toIso8601String(),
            'webviewUrl': result['url']?.toString() ?? uri?.toString() ?? '',
            'flutterUrl': uri?.toString() ?? '',
            'title': result['title']?.toString() ?? '',
            'diagnostics': diagnostics,
            'html': html,
          });
      final String path = await logger.writeDiagnosticFile(
        'rsapp-webview-snapshot.json',
        snapshot,
      );

      logger.log(
        'webview_html_snapshot_saved',
        details: <String, Object?>{
          'url': result['url']?.toString() ?? uri?.toString() ?? '',
          'path': path,
          'htmlLength': html.length,
          'snapshotLength': snapshot.length,
          'diagnostics': diagnostics,
        },
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      logger.logError('webview_html_snapshot_error', error, stackTrace);
    }
  }

  Future<void> _injectAppCssClasses(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: '''
          (function() {
            var html = document.documentElement;
            var body = document.body;
            if (!html && !body) return;

            var classes = ['rsapp', 'rsapp-webview'];
            var ua = (navigator.userAgent || '').toLowerCase();
            if (ua.indexOf('android') >= 0) {
              classes.push('rsapp-android');
            } else if (ua.indexOf('iphone') >= 0 || ua.indexOf('ipad') >= 0 || ua.indexOf('ipod') >= 0) {
              classes.push('rsapp-ios');
            }

            if (html) {
              html.classList.remove('rsapp-hide');
              for (var i = 0; i < classes.length; i++) {
                html.classList.add(classes[i]);
              }
            }
            if (body) {
              body.classList.remove('rsapp-hide');
              for (var j = 0; j < classes.length; j++) {
                body.classList.add(classes[j]);
              }
            }

            function setImportant(element, property, value) {
              if (!element || !element.style) return;
              element.style.setProperty(property, value, 'important');
            }

            function compactHeaderActions() {
              var subscribeHeader = document.getElementById('subscribe-header-mobile');
              var loginHeader = document.getElementById('login-header');
              var collapsedHeaderToggle = document.querySelector('.elementor-widget-foxiz-collapse-toggle');
              if (collapsedHeaderToggle) {
                collapsedHeaderToggle.setAttribute('aria-hidden', 'true');
                collapsedHeaderToggle.remove();
              }
              if (!subscribeHeader || !loginHeader) return;

              var headerActions = subscribeHeader.parentElement;
              if (!headerActions || !headerActions.contains(loginHeader)) return;

              headerActions.classList.add('rsapp-header-actions');
              setImportant(headerActions, 'display', 'flex');
              setImportant(headerActions, 'flex-direction', 'row');
              setImportant(headerActions, 'flex-wrap', 'nowrap');
              setImportant(headerActions, 'align-items', 'center');
              setImportant(headerActions, 'justify-content', 'flex-end');
              setImportant(headerActions, 'gap', '8px');
              setImportant(headerActions, 'column-gap', '8px');
              setImportant(headerActions, 'row-gap', '0');
              setImportant(headerActions, 'width', 'auto');
              setImportant(headerActions, 'min-width', '0');
              setImportant(headerActions, 'max-width', 'max-content');
              setImportant(headerActions, 'margin-left', 'auto');
              setImportant(headerActions, '--justify-content', 'flex-end');
              setImportant(headerActions, '--align-items', 'center');
              setImportant(headerActions, '--gap', '8px');
              setImportant(headerActions, '--row-gap', '0');
              setImportant(headerActions, '--column-gap', '8px');

              [subscribeHeader, loginHeader].forEach(function(element) {
                setImportant(element, 'flex', '0 0 auto');
                setImportant(element, 'width', 'auto');
                setImportant(element, 'min-width', '0');
                setImportant(element, 'max-width', 'max-content');
                setImportant(element, 'margin', '0');
              });
              setImportant(subscribeHeader, 'order', '1');
              setImportant(loginHeader, 'order', '2');
              setImportant(loginHeader, 'z-index', '2');
              setImportant(loginHeader, 'padding-right', '30px');

              loginHeader
                .querySelectorAll('.pab-mobile-account-toggle, .login-toggle')
                .forEach(function(element) {
                  setImportant(element, 'padding-right', '30px');
                  setImportant(element, 'box-sizing', 'content-box');
                });

              window.requestAnimationFrame(function() {
                var subscribeRect = subscribeHeader.getBoundingClientRect();
                var loginRect = loginHeader.getBoundingClientRect();
                var visibleGap = loginRect.left - subscribeRect.right;
                var targetGap = 8;
                if (visibleGap > targetGap + 2) {
                  setImportant(
                    loginHeader,
                    'transform',
                    'translateX(-' + Math.round(visibleGap - targetGap) + 'px)'
                  );
                } else {
                  setImportant(loginHeader, 'transform', 'none');
                }
              });
            }

            var subscribeHeader = document.getElementById('subscribe-header-mobile');
            var loginHeader = document.getElementById('login-header');
            var collapsedHeaderToggle = document.querySelector('.elementor-widget-foxiz-collapse-toggle');
            if (subscribeHeader && loginHeader) {
              var headerActions = subscribeHeader.parentElement;
              if (headerActions && headerActions.contains(loginHeader)) {
                headerActions.classList.add('rsapp-header-actions');
              }
            }
            if (collapsedHeaderToggle) {
              collapsedHeaderToggle.setAttribute('aria-hidden', 'true');
            }
            compactHeaderActions();
            window.setTimeout(compactHeaderActions, 80);
            window.setTimeout(compactHeaderActions, 300);

            if (!document.getElementById('rsapp-mobile-css')) {
              var style = document.createElement('style');
              style.id = 'rsapp-mobile-css';
              style.type = 'text/css';
              style.appendChild(document.createTextNode(
                [
                  'html.rsapp,html.rsapp body{touch-action:pan-x pan-y!important;}',
                  'html.rsapp .rsapp-hide,html.rsapp .pab-vx-filters-label.rsapp-hide,html.rsapp .mobile-toggle-wrap,html.rsapp .elementor-widget-foxiz-collapse-toggle{display:none!important;}',
                  'html.rsapp .rsapp-header-actions{display:flex!important;flex-direction:row!important;flex-wrap:nowrap!important;align-items:center!important;justify-content:flex-end!important;gap:8px!important;width:auto!important;min-width:0!important;max-width:max-content!important;margin-left:auto!important;--justify-content:flex-end!important;--align-items:center!important;--gap:8px!important;--row-gap:0!important;--column-gap:8px!important;}',
                  'html.rsapp body.logged-in #site-header .rsapp-header-actions,html.rsapp body.logged-in #site-header .elementor-element-d84ae9c{display:flex!important;flex-direction:row!important;flex-wrap:nowrap!important;align-items:center!important;justify-content:flex-end!important;gap:8px!important;width:auto!important;min-width:0!important;max-width:max-content!important;margin-left:auto!important;--justify-content:flex-end!important;--align-items:center!important;--gap:8px!important;--row-gap:0!important;--column-gap:8px!important;}',
                  'html.rsapp .rsapp-header-actions>#subscribe-header-mobile,html.rsapp .rsapp-header-actions>#login-header{flex:0 0 auto!important;width:auto!important;max-width:max-content!important;margin:0!important;}',
                  'html.rsapp .rsapp-header-actions>#subscribe-header-mobile{order:1!important;}',
                  'html.rsapp .rsapp-header-actions>#login-header,html.rsapp body.logged-in #site-header #login-header{order:2!important;display:block!important;flex:0 0 auto!important;width:auto!important;max-width:max-content!important;margin:0!important;margin-left:0!important;padding-right:30px!important;}',
                  'html.rsapp #site-header #login-header .pab-mobile-account-toggle,html.rsapp #site-header #login-header .login-toggle{padding-right:30px!important;box-sizing:content-box!important;}',
                  'html.rsapp .rsapp-header-actions>.elementor-widget-foxiz-collapse-toggle{order:3!important;flex:0 0 0!important;width:0!important;min-width:0!important;max-width:0!important;margin:0!important;padding:0!important;overflow:hidden!important;}',
                  'html.rsapp .pab-vx-filters-row{display:block!important;overflow:hidden!important;}',
                  'html.rsapp .pab-vx-filters-label:not(.rsapp-hide){display:block!important;margin:0 0 8px!important;}',
                  'html.rsapp .pab-vx-filters{display:flex!important;flex-wrap:nowrap!important;gap:9px!important;overflow-x:auto!important;overflow-y:hidden!important;-webkit-overflow-scrolling:touch!important;scroll-snap-type:x proximity!important;padding:0 18px 12px 22px!important;margin:0!important;}',
                  'html.rsapp .pab-vx-filter-btn{flex:0 0 auto!important;white-space:nowrap!important;scroll-snap-align:start!important;border:1.5px solid #06263F!important;border-radius:999px!important;background:#FFFFFF!important;color:#06263F!important;padding:9px 14px!important;font-weight:700!important;line-height:1!important;box-shadow:0 2px 8px rgba(6,38,63,.08)!important;}',
                  'html.rsapp .pab-vx-filter-btn.is-active{background:#06263F!important;border-color:#06263F!important;color:#FFFFFF!important;box-shadow:0 3px 10px rgba(6,38,63,.22)!important;}',
                  'html.rsapp .pab-vx-filters::-webkit-scrollbar{display:none!important;}',
                  'html.rsapp .pab-vx-filters{scrollbar-width:none!important;}',
                ].join('')
              ));
              (document.head || html || body).appendChild(style);
            }

            var viewportContent = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
            var viewport = document.querySelector('meta[name="viewport"]');
            if (!viewport) {
              viewport = document.createElement('meta');
              viewport.setAttribute('name', 'viewport');
              (document.head || html || body).appendChild(viewport);
            }
            viewport.setAttribute('content', viewportContent);

            if (!window.rsappDisableZoomReady) {
              window.rsappDisableZoomReady = true;
              ['gesturestart', 'gesturechange', 'gestureend'].forEach(function(eventName) {
                document.addEventListener(eventName, function(event) {
                  event.preventDefault();
                }, { passive: false });
              });
              document.addEventListener('touchmove', function(event) {
                if (event.touches && event.touches.length > 1) {
                  event.preventDefault();
                }
              }, { passive: false });
              document.addEventListener('wheel', function(event) {
                if (event.ctrlKey) {
                  event.preventDefault();
                }
              }, { passive: false });
            }

            window.rsappCenterActiveFilter = function(button) {
              var active = button || document.querySelector('.pab-vx-filter-btn.is-active');
              if (!active) return;
              var rail = active.closest('.pab-vx-filters');
              if (!rail) return;
              var target = active.offsetLeft - (rail.clientWidth - active.offsetWidth) / 2;
              rail.scrollTo({
                left: Math.max(0, target),
                behavior: 'smooth'
              });
            };

            if (!window.rsappFilterCenteringReady) {
              window.rsappFilterCenteringReady = true;
              document.addEventListener('click', function(event) {
                var button = event.target && event.target.closest
                  ? event.target.closest('.pab-vx-filter-btn')
                  : null;
                if (!button) return;
                window.setTimeout(function() {
                  window.rsappCenterActiveFilter(button);
                }, 80);
              }, true);

              var observer = new MutationObserver(function(mutations) {
                for (var i = 0; i < mutations.length; i++) {
                  var target = mutations[i].target;
                  if (target && target.classList && target.classList.contains('is-active')) {
                    window.rsappCenterActiveFilter(target);
                    break;
                  }
                }
              });
              observer.observe(document.documentElement, {
                attributes: true,
                attributeFilter: ['class'],
                subtree: true
              });
            }

            window.setTimeout(function() {
              window.rsappCenterActiveFilter();
            }, 120);
          })();
        ''',
      );
    } catch (_) {
      // CSS hook injection is non-critical.
    }
  }
}
