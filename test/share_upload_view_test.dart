import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:axplayer/src/download_bridge.dart';
import 'package:axplayer/src/share_upload_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(List<SmbPickedFile> files) =>
      MaterialApp(home: ShareUploadView(files: files));

  Future<void> mockChannel(MethodCall? Function() onCall) async {
    const channel = MethodChannel('axplayer/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => onCall());
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  testWidgets('renders the shared video list', (tester) async {
    await mockChannel(() => null);

    await tester.pumpWidget(
      wrap(const [
        SmbPickedFile(uri: 'content://1', name: 'a.mp4', size: 1048576),
        SmbPickedFile(uri: 'content://2', name: 'b.mp4', size: 2097152),
      ]),
    );
    await tester.pump();

    expect(find.text('a.mp4'), findsOneWidget);
    expect(find.text('b.mp4'), findsOneWidget);
    expect(find.text('1.0 MB'), findsOneWidget);
    expect(find.text('上传到 SMB'), findsOneWidget);
  });

  testWidgets('removing the only item disables the upload button', (
    tester,
  ) async {
    await mockChannel(() => null);

    await tester.pumpWidget(
      wrap(const [
        SmbPickedFile(uri: 'content://1', name: 'a.mp4', size: 1024),
      ]),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.text('a.mp4'), findsNothing);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.text('没有可上传的视频'), findsOneWidget);
  });
}
