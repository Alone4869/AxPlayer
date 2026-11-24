import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:axplayer/src/settings_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings shows the upload local video entry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(const MaterialApp(home: SettingsView()));
    await tester.pump();

    expect(find.text('上传本地视频'), findsOneWidget);
    expect(find.text('选择本机视频并上传到 SMB'), findsOneWidget);
    expect(find.byIcon(Icons.video_library_outlined), findsOneWidget);
  });
}
