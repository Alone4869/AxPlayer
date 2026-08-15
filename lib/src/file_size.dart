String formatFileSize(int bytes) {
  if (bytes <= 0) return '—';
  final megabytes = bytes / 1024 / 1024;
  if (megabytes < 1024) return '${megabytes.toStringAsFixed(1)} MB';
  return '${(megabytes / 1024).toStringAsFixed(2)} GB';
}