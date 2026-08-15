import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8downloader/src/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('consuming shared videos opens the share upload view',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('m3u8_downloader/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumeSharedVideos') {
        return [
          {'uri': 'content://share/1', 'name': 'shared.mp4', 'size': 1048576},
        ];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('分享到 SMB'), findsOneWidget);
    expect(find.text('shared.mp4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty share does not open the upload view', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('m3u8_downloader/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('分享到 SMB'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}