import 'package:flutter/material.dart';

const String kAppName = 'PraxisMedia';
const String kBaseUrl = 'https://praxismedia.fr/';
const String kRegisterEndpoint = '/wp-json/rsapp/v1/register-token';
const String kRegisterTokenKey = 'RSAPP_2026_05_20_9z3c4x2a7t4e8c4d1e0f';
const String kRegisterTokenHeader = 'X-RSAPP-KEY';
const String kAppUserAgentTag = 'RSAPP/1.0';

class MenuDestination {
  const MenuDestination({
    required this.label,
    required this.path,
    required this.icon,
  });

  final String label;
  final String path;
  final IconData icon;
}

const List<MenuDestination> kMenuDestinations = <MenuDestination>[
  MenuDestination(label: 'Home', path: '/', icon: Icons.home_rounded),
  MenuDestination(
    label: 'Votes',
    path: '/liste-referendums/',
    icon: Icons.how_to_vote_rounded,
  ),
  MenuDestination(
    label: 'Vidéos',
    path: '/type/video/',
    icon: Icons.play_circle_fill_rounded,
  ),
  MenuDestination(
    label: 'Articles',
    path: '/articles/',
    icon: Icons.article_rounded,
  ),
  MenuDestination(
    label: 'Podcasts',
    path: '/podcasts/',
    icon: Icons.podcasts_rounded,
  ),
];
