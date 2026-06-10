import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/app_state.dart';
import '../services/app_logger.dart';
import '../ui/startup_splash.dart';
import '../utils/url_utils.dart';

class AppWebView extends StatefulWidget {
  const AppWebView({super.key});

  @override
  State<AppWebView> createState() => _AppWebViewState();
}

class _AppWebViewState extends State<AppWebView>
    with AutomaticKeepAliveClientMixin<AppWebView> {
  InAppWebViewController? _controller;
  int _lastConsumedRequestId = -1;
  bool _isLoading = true;
  bool _showStartupSplash = true;
  String? _lastError;
  Timer? _startupSplashTimer;
  bool _loggedFirstBuild = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
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
    _startupSplashTimer?.cancel();
    super.dispose();
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
            mediaPlaybackRequiresUserGesture: false,
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
                  context.read<AppLogger>().log(
                    'webview_external_navigation',
                    details: <String, Object?>{
                      'url': rawUri.toString(),
                      'mainFrame': navigationAction.isForMainFrame,
                      'hasGesture': navigationAction.hasGesture,
                      'navigationType':
                          navigationAction.navigationType?.toString() ?? '',
                      'allowed': isUserNavigation,
                    },
                  );
                  if (!isUserNavigation) {
                    return NavigationActionPolicy.CANCEL;
                  }
                  await launchUrl(rawUri, mode: LaunchMode.externalApplication);
                  return NavigationActionPolicy.CANCEL;
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

            if (!document.getElementById('rsapp-mobile-css')) {
              var style = document.createElement('style');
              style.id = 'rsapp-mobile-css';
              style.type = 'text/css';
              style.appendChild(document.createTextNode(
                [
                  'html.rsapp .rsapp-hide{display:none!important;}',
                  'html.rsapp .pab-vx-filters-row{display:block!important;overflow:hidden!important;}',
                  'html.rsapp .pab-vx-filters-label{display:block!important;margin:0 0 8px!important;}',
                  'html.rsapp .pab-vx-filters{display:flex!important;flex-wrap:nowrap!important;gap:9px!important;overflow-x:auto!important;overflow-y:hidden!important;-webkit-overflow-scrolling:touch!important;scroll-snap-type:x proximity!important;padding:0 18px 12px 22px!important;margin:0!important;}',
                  'html.rsapp .pab-vx-filter-btn{flex:0 0 auto!important;white-space:nowrap!important;scroll-snap-align:start!important;border:1.5px solid #06263F!important;border-radius:999px!important;background:#FFFFFF!important;color:#06263F!important;padding:9px 14px!important;font-weight:700!important;line-height:1!important;box-shadow:0 2px 8px rgba(6,38,63,.08)!important;}',
                  'html.rsapp .pab-vx-filter-btn.is-active{background:#06263F!important;border-color:#06263F!important;color:#FFFFFF!important;box-shadow:0 3px 10px rgba(6,38,63,.22)!important;}',
                  'html.rsapp .pab-vx-filters::-webkit-scrollbar{display:none!important;}',
                  'html.rsapp .pab-vx-filters{scrollbar-width:none!important;}',
                ].join('')
              ));
              (document.head || html || body).appendChild(style);
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
