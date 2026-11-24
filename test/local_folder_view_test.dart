import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:axplayer/src/local_folder_view.dart';
import 'package:axplayer/src/server_settings.dart';

const _channel = MethodChannel('axplayer/methods');

ServerConfig _config() => ServerConfig(
  id: 'local-1',
  type: ServerType.local,
  name: '我的电影',
  url: 'content://com.android.externalstorage.documents/tree/primary%3AMovies',
  createdAt: DateTime.parse('2026-11-25T10:00:00'),
);

Map<String, Object?> _video(String name, int size, int modified) => {
  'uri': 'content://tree/doc/$name',
  'name': name,
  'size': size,
  'mimeType': 'video/mp4',
  'lastModified': modified,
  'relativePath': name,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  void mockBridge({
    required List<Map<String, Object?>> videos,
    Map<String, Object?> history = const {},
  }) {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'listLocalVideos':
              return videos;
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
        home: LocalFolderView(config: _config()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders folder name, count and video tiles', (tester) async {
    mockBridge(
      videos: [
        _video('第一集.mp4', 1024 * 1024 * 300, 2000),
        _video('第二集.mp4', 1024 * 1024 * 150, 1000),
      ],
    );

    await pumpView(tester);

    expect(find.text('我的电影'), findsOneWidget);
    expect(find.text('第一集.mp4'), findsOneWidget);
    expect(find.text('第二集.mp4'), findsOneWidget);
    expect(find.text('全部视频'), findsOneWidget);
    expect(find.text('2 个'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows continue watching for a partially played video', (
    tester,
  ) async {
    mockBridge(
      videos: [
        _video('第一集.mp4', 1024 * 1024 * 300, 2000),
        _video('第二集.mp4', 1024 * 1024 * 150, 1000),
      ],
      history: {
        'content://tree/doc/第一集.mp4': {
          'uri': 'content://tree/doc/第一集.mp4',
          'position': 120000,
          'duration': 600000,
          'updatedAt': 5000,
          'title': '第一集.mp4',
        },
      },
    );

    await pumpView(tester);

    expect(find.text('继续观看'), findsOneWidget);
    expect(find.text('还剩 08:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the empty state when the folder has no videos', (
    tester,
  ) async {
    mockBridge(videos: const []);

    await pumpView(tester);

    expect(find.text('这个文件夹里没有视频'), findsOneWidget);
    expect(find.text('更换文件夹'), findsNothing);
    expect(find.text('换个文件夹'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('surfaces a permission failure instead of an empty folder', (
    tester,
  ) async {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'listLocalVideos') {
            throw PlatformException(
              code: 'operation_failed',
              message: '文件夹授权已失效，请重新选择',
            );
          }
          return null;
        });

    await pumpView(tester);

    expect(find.text('读不到这个文件夹'), findsOneWidget);
    expect(find.textContaining('重新选择'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
