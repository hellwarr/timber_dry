// File generated for TimberDry Desktop & Cross-Platform Firebase support.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        return linux;
      default:
        return web;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyB1z1pbtq5JOlWpdROUMTzwc8Ld21i4Rj8',
    appId: '1:278478916441:web:a7b7fda04bd28ed5b89a48',
    messagingSenderId: '278478916441',
    projectId: 'timber-dry-pro',
    authDomain: 'timber-dry-pro.firebaseapp.com',
    storageBucket: 'timber-dry-pro.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyB1z1pbtq5JOlWpdROUMTzwc8Ld21i4Rj8',
    appId: '1:278478916441:android:a7b7fda04bd28ed5b89a48',
    messagingSenderId: '278478916441',
    projectId: 'timber-dry-pro',
    storageBucket: 'timber-dry-pro.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyB1z1pbtq5JOlWpdROUMTzwc8Ld21i4Rj8',
    appId: '1:278478916441:ios:a7b7fda04bd28ed5b89a48',
    messagingSenderId: '278478916441',
    projectId: 'timber-dry-pro',
    storageBucket: 'timber-dry-pro.firebasestorage.app',
    iosBundleId: 'com.astra.timberdry.timberDry',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyB1z1pbtq5JOlWpdROUMTzwc8Ld21i4Rj8',
    appId: '1:278478916441:ios:a7b7fda04bd28ed5b89a48',
    messagingSenderId: '278478916441',
    projectId: 'timber-dry-pro',
    storageBucket: 'timber-dry-pro.firebasestorage.app',
    iosBundleId: 'com.astra.timberdry.timberDry',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyB1z1pbtq5JOlWpdROUMTzwc8Ld21i4Rj8',
    appId: '1:278478916441:web:a7b7fda04bd28ed5b89a48',
    messagingSenderId: '278478916441',
    projectId: 'timber-dry-pro',
    authDomain: 'timber-dry-pro.firebaseapp.com',
    storageBucket: 'timber-dry-pro.firebasestorage.app',
  );

  static const FirebaseOptions linux = FirebaseOptions(
    apiKey: 'AIzaSyB1z1pbtq5JOlWpdROUMTzwc8Ld21i4Rj8',
    appId: '1:278478916441:web:a7b7fda04bd28ed5b89a48',
    messagingSenderId: '278478916441',
    projectId: 'timber-dry-pro',
    authDomain: 'timber-dry-pro.firebaseapp.com',
    storageBucket: 'timber-dry-pro.firebasestorage.app',
  );
}
