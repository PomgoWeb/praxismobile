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
  bool _hasCompletedFirstLoad = false;
  String? _lastError;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final AppState appState = context.watch<AppState>();

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
          },
          onLoadStart: (InAppWebViewController controller, WebUri? uri) {
            setState(() {
              _isLoading = true;
              _lastError = null;
            });
            context.read<AppLogger>().log(
              'webview_load_start',
              details: <String, Object?>{'url': uri?.toString() ?? ''},
            );
          },
          onLoadStop: (InAppWebViewController controller, WebUri? uri) {
            setState(() {
              _isLoading = false;
              _hasCompletedFirstLoad = true;
              _lastError = null;
            });
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
                  _isLoading = false;
                  _lastError = error.description;
                });
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
                  await launchUrl(rawUri, mode: LaunchMode.externalApplication);
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
        ),
        if (!_hasCompletedFirstLoad)
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

            var classes = ['rsapp', 'rsapp-hide', 'rsapp-webview'];
            var ua = (navigator.userAgent || '').toLowerCase();
            if (ua.indexOf('android') >= 0) {
              classes.push('rsapp-android');
            } else if (ua.indexOf('iphone') >= 0 || ua.indexOf('ipad') >= 0 || ua.indexOf('ipod') >= 0) {
              classes.push('rsapp-ios');
            }

            if (html) {
              for (var i = 0; i < classes.length; i++) {
                html.classList.add(classes[i]);
              }
            }
            if (body) {
              for (var j = 0; j < classes.length; j++) {
                body.classList.add(classes[j]);
              }
            }
          })();
        ''',
      );
    } catch (_) {
      // CSS hook injection is non-critical.
    }
  }
}
