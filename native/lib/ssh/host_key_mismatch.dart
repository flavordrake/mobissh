// Structured CHANGED-host-key evidence (#1235).
//
// The fail-closed mismatch path (#1108) used to surface only an error STRING,
// so the UI had nothing to act on and the owner was locked out of a rebuilt
// host. This value travels on SshSessionData and across the task IPC so the
// failure view can offer a deliberate review + forget.

/// A refused host key: what was stored, what the server offered, and for which
/// host:port. [jumpHop] is true when the host is a jump hop, not the target.
class HostKeyMismatch {
  const HostKeyMismatch({
    required this.host,
    required this.port,
    required this.keyType,
    required this.storedFingerprint,
    required this.offeredFingerprint,
    this.jumpHop = false,
  });

  final String host;
  final int port;
  final String keyType;
  final String storedFingerprint;
  final String offeredFingerprint;
  final bool jumpHop;

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'keyType': keyType,
    'stored': storedFingerprint,
    'offered': offeredFingerprint,
    'jumpHop': jumpHop,
  };

  static HostKeyMismatch fromJson(Map<String, dynamic> json) => HostKeyMismatch(
    host: json['host'] as String,
    port: json['port'] as int,
    keyType: json['keyType'] as String,
    storedFingerprint: json['stored'] as String,
    offeredFingerprint: json['offered'] as String,
    jumpHop: json['jumpHop'] as bool? ?? false,
  );
}
