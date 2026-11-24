import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:axplayer/src/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('consuming shared videos opens the share upload view',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('axplayer/methods');
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
    const channel = MethodChannel('axplayer/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('分享到 SMB'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resuming the app consumes a hot share and opens the upload view',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('axplayer/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var consumeCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumeSharedVideos') {
        consumeCalls++;
        if (consumeCalls == 1) return null;
        return [
          {'uri': 'content://share/2', 'name': 'resumed.mp4', 'size': 1048576},
        ];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('分享到 SMB'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(consumeCalls, 2);
    expect(find.text('分享到 SMB'), findsOneWidget);
    expect(find.text('resumed.mp4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
