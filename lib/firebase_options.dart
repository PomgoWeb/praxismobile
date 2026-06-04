import 'dart:io';

import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (Platform.isIOS) {
      return ios;
    }
    if (Platform.isAndroid) {
      return android;
    }
    throw UnsupportedError(
      'DefaultFirebaseOptions are not configured for this platform.',
    );
  }

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAQZPjOuSgZ-HiDtsWR3DT8Ve2ZG1Ff3jQ',
    appId: '1:763051115374:ios:910bfe2b2099ca33f4777f',
    messagingSenderId: '763051115374',
    projectId: 'praxismedia-77ad3',
    storageBucket: 'praxismedia-77ad3.firebasestorage.app',
    iosBundleId: 'com.praxismedia.ios',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyC4XY2bKK-BnlQDUk_TJw1A_LbfSrmjEaM',
    appId: '1:763051115374:android:58aa71acaf51b486f4777f',
    messagingSenderId: '763051115374',
    projectId: 'praxismedia-77ad3',
    storageBucket: 'praxismedia-77ad3.firebasestorage.app',
  );
}
