# Mobile App (Flutter)

## Pré-requis

- Flutter 3.38+
- Android Studio + SDK
- Xcode (pour builds iOS, sur macOS)
- Projet Firebase configuré pour:
  - Android `com.praxismedia.android`
  - iOS `com.praxismedia.ios`

## Setup

1. `flutter pub get`
2. Ajouter:
   - `android/app/google-services.json`
   - `ios/Runner/GoogleService-Info.plist`
3. Vérifier que `GoogleService-Info.plist` est bien dans la target `Runner`.
4. Lancer:
   - `flutter run`

## Build release Android

1. Créer `android/key.properties` (non versionné).
2. Exécuter:
   - `flutter clean`
   - `flutter pub get`
   - `flutter build appbundle --release --build-number=<N>`
3. Respecter un `versionCode` strictement croissant.

## Build release iOS (manuel)

Voir [docs/cicd-ios-manual.md](../docs/cicd-ios-manual.md).

## Variables centralisées

Fichier: `lib/config/app_config.dart`
- `kAppName`
- `kBaseUrl`
- `kRegisterEndpoint`
- `kRegisterTokenHeader`
- `kRegisterTokenKey`
- `kAppUserAgentTag`
