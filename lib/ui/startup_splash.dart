import 'package:flutter/material.dart';

const Color _kSplashBackground = Color(0xFF06263F);
const Color _kSplashAccent = Color(0xFFC10F00);

class StartupSplash extends StatelessWidget {
  const StartupSplash({super.key, this.showLoader = true});

  final bool showLoader;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _kSplashBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Image.asset('assets/icon/app_logo.png', width: 56, height: 56),
            if (showLoader) ...<Widget>[
              const SizedBox(height: 28),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: _kSplashAccent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
