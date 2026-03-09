'use strict';

/**
 * CSWSH prevention (issue #83).
 *
 * Cross-Site WebSocket Hijacking: a malicious page can open a WS connection to
 * this server using the victim's cookies/credentials. Comparing the Origin
 * header against the Host header defeats CSWSH without breaking non-browser
 * clients (native tools like wscat omit Origin, which we allow).
 *
 * @param {string|undefined} origin   - value of the Origin request header
 * @param {string|undefined} host     - value of the Host request header
 * @param {string[]}         allowlist - extra allowed origin URLs
 * @returns {boolean} true if the connection should be permitted
 */
function isOriginAllowed(origin, host, allowlist) {
  // Non-browser clients (wscat, ssh2 tools) omit Origin — allow them.
  if (!origin) return true;

  // Extract just the hostname+port from the Origin URL for comparison.
  let originHost;
  try {
    originHost = new URL(origin).host;
  } catch (_) {
    // Malformed Origin header — reject it.
    return false;
  }

  // Same-origin: Origin host matches the HTTP Host header.
  if (host && originHost === host) return true;

  // Allowlist: explicit extra origins (normalised to their host component).
  for (const allowed of allowlist) {
    try {
      if (new URL(allowed).host === originHost) return true;
    } catch (_) {
      // Skip malformed entries in the allowlist.
    }
  }

  return false;
}

module.exports = { isOriginAllowed };
