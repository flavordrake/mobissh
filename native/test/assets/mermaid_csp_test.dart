// Asset-content test for the offline mermaid render host's egress block
// (#1107 sibling).
//
// The mermaid host runs our BUNDLED mermaid.js over diagram DATA that can come
// from untrusted content. mermaid's own `securityLevel: 'strict'` sanitizes
// labels but enforces NO network policy — a mermaid-label injection could still
// beacon out. The host page must carry a strict Content-Security-Policy whose
// `default-src 'none'` + `connect-src 'none'` (plus data:-only img/font) block
// ALL network egress while still running the local bundled scripts.
//
// Whether the WebView engine actually enforces the <meta> CSP is engine
// behavior — that is device-validation-pending. This test pins the policy in
// the shipped asset so it can never silently regress.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = File('assets/mermaid/mermaid_host.html').readAsStringSync();
  final boot = File('assets/mermaid/mermaid_boot.js').readAsStringSync();

  test('host declares a Content-Security-Policy meta', () {
    expect(
      host.contains('http-equiv="Content-Security-Policy"'),
      isTrue,
      reason: 'mermaid host must carry a CSP meta as the egress block',
    );
  });

  test('CSP blocks all network egress', () {
    // The two load-bearing egress directives.
    expect(host.contains("default-src 'none'"), isTrue);
    expect(host.contains("connect-src 'none'"), isTrue);
    // img/font restricted to inline data: (no remote fetch beacon).
    expect(host.contains('img-src data:'), isTrue);
    expect(host.contains("font-src data: 'self'"), isTrue);
    // Lock down the remaining escape hatches.
    expect(host.contains("base-uri 'none'"), isTrue);
    expect(host.contains("form-action 'none'"), isTrue);
  });

  test('scripts stay local: script-src is self, no unsafe-inline', () {
    expect(host.contains("script-src 'self'"), isTrue);
    // A strict script-src must not open an inline-script hole.
    expect(
      host.contains("script-src 'self' 'unsafe-inline'") ||
          host.contains("script-src 'unsafe-inline'"),
      isFalse,
      reason: 'inline scripts were externalized so unsafe-inline is not needed',
    );
  });

  test('bundled + externalized scripts are referenced, no inline boot block', () {
    // Bundled engine still loads locally.
    expect(host.contains('src="mermaid.min.js"'), isTrue);
    // Boot logic was externalized so `script-src 'self'` can run it.
    expect(host.contains('src="mermaid_boot.js"'), isTrue);
    // Every <script> tag must be a `src=` include — no inline script body, or
    // the strict `script-src 'self'` (no 'unsafe-inline') would block it. Strip
    // HTML comments first so prose mentioning `<script src>` isn't counted.
    final markup = host.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    final scriptTags = RegExp(r'<script\b[^>]*>').allMatches(markup).toList();
    expect(scriptTags.length, 2);
    for (final m in scriptTags) {
      expect(
        m.group(0)!.contains('src='),
        isTrue,
        reason: 'inline <script> would be blocked by script-src \'self\'',
      );
    }
    // The externalized boot file still defines the render entrypoint + strict
    // mermaid init, so the diagram pipeline is intact under the policy.
    expect(boot.contains('window.renderMermaid'), isTrue);
    expect(boot.contains("securityLevel: 'strict'"), isTrue);
  });
}
