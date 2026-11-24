import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:axplayer/src/playback_history_view.dart';

const _channel = MethodChannel('axplayer/methods');

Map<String, Object?> _entry(
  String uri, {
  required int position,
  required int duration,
  required int updatedAt,
  String title = '',
}) => {
  'uri': uri,
  'position': position,
  'duration': duration,
  'updatedAt': updatedAt,
  'title': title,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mockHistory(Map<String, Object?> history) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'getPlaybackHistory':
              return history;
            case 'getLocalVideoThumbnail':
              return null;
          }
          return null;
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<void> pumpView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const PlaybackHistoryView(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists entries newest first', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    mockHistory({
      'content://doc/old': _entry(
        'content://doc/old',
        position: 60000,
        duration: 600000,
        updatedAt: now - 3 * 24 * 3600 * 1000,
        title: '旧的.mp4',
      ),
      'content://doc/new': _entry(
        'content://doc/new',
        position: 30000,
        duration: 300000,
        updatedAt: now - 5 * 60 * 1000,
        title: '新的.mp4',
      ),
    });

    await pumpView(tester);

    expect(find.text('播放历史'), findsOneWidget);
    expect(find.text('最近 2 条'), findsOneWidget);
    expect(find.text('新的.mp4'), findsOneWidget);
    expect(find.text('旧的.mp4'), findsOneWidget);

    // 新的排在旧的前面
    final newer = tester.getTopLeft(find.text('新的.mp4')).dy;
    final older = tester.getTopLeft(find.text('旧的.mp4')).dy;
    expect(newer, lessThan(older));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows remaining time and relative time', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    mockHistory({
      'content://doc/a': _entry(
        'content://doc/a',
        position: 120000,
        duration: 600000,
        updatedAt: now - 2 * 3600 * 1000,
        title: '第一集.mp4',
      ),
    });

    await pumpView(tester);

    expect(find.textContaining('还剩 08:00'), findsOneWidget);
    expect(find.textContaining('2 小时前'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('falls back to the file name when the title is empty', (
    tester,
  ) async {
    mockHistory({
      'content://tree/doc/clip.mp4': _entry(
        'content://tree/doc/clip.mp4',
        position: 1000,
        duration: 0,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    });

    await pumpView(tester);

    expect(find.text('clip.mp4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('caps the list at fifty entries', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    mockHistory({
      for (var i = 0; i < 60; i++)
        'content://doc/$i': _entry(
          'content://doc/$i',
          position: 1000,
          duration: 60000,
          updatedAt: now - i * 1000,
          title: '视频 $i',
        ),
    });

    await pumpView(tester);

    expect(find.text('最近 50 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the empty state without history', (tester) async {
    mockHistory(const {});

    await pumpView(tester);

    expect(find.text('还没有播放记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
