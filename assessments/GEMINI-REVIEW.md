# Security Assessment Report: MobiSSH (Gemini CLI)

## Executive Summary
MobiSSH demonstrates a strong security-first architecture for a personal tool. The credential vault implementation is industry-standard (AES-GCM, PBKDF2-600k, WebAuthn PRF), and the PWA follows security best practices (CSP, no inline scripts, proper escaping). The primary risks identified are related to the WebSocket bridge's authentication bypass when used with Tailscale and its susceptibility to Cross-Site WebSocket Hijacking (CSWSH).

---

## Risk Prioritization

| Rank | Risk | Severity | Impact | Mitigation Status |
| :--- | :--- | :--- | :--- | :--- |
| **1** | **CSWSH when `TS_SERVE=1`** | **Medium** | Unauthorized bridge access | **Unmitigated** (Missing Origin check) |
| **2** | **Weak SSRF Protection** | **Low** | Internal network probing | **Partial** (String-based, opt-out available) |
| **3** | **Insecure Transport (Non-VPN)** | **Low** | Credential theft (sniffing) | **Mitigated** (Warning in UI, Tailscale default) |
| **4** | **Root Container Execution** | **Low** | Host compromise escalation | **Unmitigated** (Docker default) |

---

## Detailed Findings & Red Team Analysis

### 1. Cross-Site WebSocket Hijacking (CSWSH)
- **Vulnerability:** When `TS_SERVE=1` (Tailscale mode), the bridge skips its per-session HMAC token authentication. The `server/index.js` does not validate the `Origin` header during the WebSocket handshake.
- **Attack Vector:** A user visits a malicious website while MobiSSH is running on their Tailscale network. The malicious site can initiate a WebSocket connection to `ws://mobissh.tailnet/`. Since no token is required and no Origin check is performed, the bridge accepts the connection.
- **Impact:** The attacker can use the bridge to attempt SSH connections to internal hosts (brute force or probing) using the user's browser as a proxy.
- **Recommendation:** Always validate the `Origin` header in `verifyClient`, even when `TS_SERVE=1`. Ensure it matches the expected host.

### 2. SSRF Protection Bypass
- **Vulnerability:** The `isPrivateHost` function uses basic string prefix matching (e.g., `127.`).
- **Attack Vector:** 
    - **DNS Rebinding:** A hostname like `attacker.com` resolving to `127.0.0.1`.
    - **Non-canonical IPs:** Using decimal (`2130706433`), hex (`0x7f.0x0.0x0.0x1`), or octal representations.
- **Impact:** Attackers can bypass the "no private addresses" restriction even if the user hasn't explicitly enabled the "Danger Zone" toggle.
- **Recommendation:** Perform IP resolution and validate the resulting numeric IP against private CIDR blocks using a robust library like `ipaddr.js` or manual bitwise checks.

### 3. Credential Vault Integrity
- **Analysis:** The vault is excellently designed. PBKDF2 with 600,000 iterations is highly resistant to brute force. The use of WebAuthn PRF for biometric unlock provides a modern, secure hardware-backed key derivation mechanism.
- **Finding:** The Data Encryption Key (DEK) is marked as `extractable` in memory. While technically a risk, it is required for the "Enroll Biometric" flow and is mitigated by the fact that an attacker with JS execution (XSS) could exfiltrate the vault content regardless of extractability.

### 4. Supply Chain & Dependencies
- **Analysis:** The project maintains a very small dependency footprint (`ssh2`, `ws`, `@xterm/xterm`).
- **Finding:** All dependencies and vendored libraries (xterm.js 6.0.0) are up-to-date as of early 2026.

---

## Conclusion
MobiSSH is a well-engineered tool that prioritizes user data safety. Addressing the CSWSH risk by adding an `Origin` header check would elevate the bridge's security to match the high standard set by the vault implementation. For its intended use case (private network over Tailscale), it provides a secure and robust platform for remote terminal management.
