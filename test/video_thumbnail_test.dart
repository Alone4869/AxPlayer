import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8downloader/src/download_bridge.dart';
import 'package:m3u8downloader/src/video_thumbnail.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('falls back to the movie icon when no thumbnail is available',
      (tester) async {
    const channel = MethodChannel('m3u8_downloader/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const task = DownloadTask(
      id: '',
      url: '',
      fileName: 'clip.mp4',
      status: DownloadStatus.completed,
      progress: 1,
      contentUri: 'content://share/1',
      fileSize: 1024,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VideoThumbnail(task: task, fallbackColor: Colors.red),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.movie_creation_outlined), findsOneWidget);
  });
}