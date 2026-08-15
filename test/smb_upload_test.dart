import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8downloader/src/smb_upload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uploading an empty picked list never touches the SMB channel',
      () async {
    const channel = MethodChannel('m3u8_downloader/methods');
    var uploadCalled = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'uploadToSmb') uploadCalled = true;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await uploadPickedVideosToSmb(null, const []);

    expect(uploadCalled, isFalse);
  });
}