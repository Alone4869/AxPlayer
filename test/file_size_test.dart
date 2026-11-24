import 'package:flutter_test/flutter_test.dart';
import 'package:axplayer/src/file_size.dart';

void main() {
  test('formatFileSize renders megabytes below a gigabyte', () {
    expect(formatFileSize(1048576), '1.0 MB');
  });

  test('formatFileSize renders gigabytes at or above a gigabyte', () {
    expect(formatFileSize(1048576 * 1024), '1.00 GB');
    expect(formatFileSize(1048576 * 2048), '2.00 GB');
  });

  test('formatFileSize renders a dash for non-positive sizes', () {
    expect(formatFileSize(0), '—');
    expect(formatFileSize(-1), '—');
  });
}
