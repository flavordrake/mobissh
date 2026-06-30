// Public Downloads publisher (#559).
//
// SFTP downloads stream to an app-private *staging* file (offset-honoring
// reassembly + length verification — see [OffsetFileSink] in sftp_download.dart).
// This service hands the finished staging file to the native side, which copies
// it into the user-visible shared Downloads collection (MediaStore on API 29+,
// the public Downloads dir on older devices). Returns a human-readable location
// like "Downloads/report.pdf" for the success snackbar.
//
// Kept separate from the sink so it's injectable: unit tests pass a fake
// publisher and never touch the platform channel.

import 'package:flutter/services.dart';

/// Copies [srcPath] into the public Downloads folder under [fileName],
/// returning the saved display location. May throw [PlatformException] /
/// [MissingPluginException] (e.g. on non-Android / test hosts) — callers
/// fall back to the staging path so a download is never lost.
typedef DownloadsPublisher =
    Future<String> Function(String srcPath, String fileName, String? mimeType);

const MethodChannel _channel = MethodChannel('mobissh/downloads');

/// Production publisher: routes to the native `mobissh/downloads` channel.
Future<String> platformPublishToDownloads(
  String srcPath,
  String fileName,
  String? mimeType,
) async {
  final result = await _channel.invokeMethod<String>('publishToDownloads', {
    'srcPath': srcPath,
    'fileName': fileName,
    'mimeType': mimeType,
  });
  if (result == null || result.isEmpty) {
    throw PlatformException(
      code: 'PUBLISH_EMPTY',
      message: 'publishToDownloads returned no location',
    );
  }
  return result;
}
