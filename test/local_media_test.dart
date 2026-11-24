import 'package:flutter_test/flutter_test.dart';
import 'package:axplayer/src/local_media.dart';

void main() {
  group('LocalVideo', () {
    test('parses an entry returned by the folder scan', () {
      final video = LocalVideo.fromMap({
        'uri':
            'content://com.android.externalstorage.documents/tree/x/document/y',
        'name': 'demo.mp4',
        'size': 1048576,
        'mimeType': 'video/mp4',
        'lastModified': 1700000000000,
        'relativePath': 'Movies/demo.mp4',
      });

      expect(
        video.uri,
        'content://com.android.externalstorage.documents/tree/x/document/y',
      );
      expect(video.name, 'demo.mp4');
      expect(video.size, 1048576);
      expect(video.relativePath, 'Movies/demo.mp4');
      expect(video.extension, 'MP4');
    });

    test('cache key changes when the file is replaced', () {
      const before = LocalVideo(
        uri: 'content://doc/1',
        name: 'clip.mp4',
        size: 10,
        mimeType: 'video/mp4',
        lastModified: 100,
        relativePath: 'clip.mp4',
      );
      const after = LocalVideo(
        uri: 'content://doc/1',
        name: 'clip.mp4',
        size: 10,
        mimeType: 'video/mp4',
        lastModified: 200,
        relativePath: 'clip.mp4',
      );

      expect(before.cacheKey, isNot(after.cacheKey));
    });

    test('handles a name without an extension', () {
      const video = LocalVideo(
        uri: 'content://doc/1',
        name: 'no-extension',
        size: 0,
        mimeType: 'video/*',
        lastModified: 0,
        relativePath: 'no-extension',
      );

      expect(video.extension, '');
    });
  });

  group('PlaybackEntry', () {
    test('reports progress and remaining time', () {
      const entry = PlaybackEntry(
        uri: 'content://doc/1',
        positionMs: 120000,
        durationMs: 600000,
        updatedAt: 1700000000000,
        title: 'demo.mp4',
      );

      expect(entry.progress, closeTo(0.2, 0.0001));
      expect(entry.remainingMs, 480000);
      expect(entry.isFinished, isFalse);
    });

    test('treats the last five seconds as finished', () {
      const entry = PlaybackEntry(
        uri: 'content://doc/1',
        positionMs: 597000,
        durationMs: 600000,
        updatedAt: 0,
        title: 'demo.mp4',
      );

      expect(entry.isFinished, isTrue);
    });

    test('stays empty when the duration is unknown', () {
      const entry = PlaybackEntry(
        uri: 'content://doc/1',
        positionMs: 5000,
        durationMs: 0,
        updatedAt: 0,
        title: 'demo.mp4',
      );

      expect(entry.progress, 0);
      expect(entry.isFinished, isFalse);
      expect(entry.remainingMs, 0);
    });
  });
}
