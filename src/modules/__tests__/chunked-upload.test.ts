import { describe, it, expect, beforeEach, vi } from 'vitest';
import { webcrypto } from 'node:crypto';

// Stub browser globals before any module imports
vi.stubGlobal('crypto', webcrypto);

const storage = new Map<string, string>();
const localStorageMock = {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
};
vi.stubGlobal('localStorage', localStorageMock);
vi.stubGlobal('location', { hostname: 'localhost' });

vi.stubGlobal('document', {
  getElementById: () => null,
  querySelector: () => null,
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  createElement: vi.fn(() => ({
    className: '',
    textContent: '',
    innerHTML: '',
    id: '',
    appendChild: vi.fn(),
    addEventListener: vi.fn(),
    querySelector: vi.fn(),
    remove: vi.fn(),
  })),
  body: { appendChild: vi.fn() },
});

const wsSendSpy = vi.fn();
vi.stubGlobal('WebSocket', Object.assign(
  class {
    onopen = null; onclose = null; onmessage = null; onerror = null;
    readyState = 1; // OPEN
    url = 'ws://localhost:8081';
    close = vi.fn();
    send = wsSendSpy;
  },
  { OPEN: 1, CLOSED: 3 },
));
vi.stubGlobal('Worker', class { onmessage = null; postMessage = vi.fn(); terminate = vi.fn(); });
vi.stubGlobal('navigator', { wakeLock: undefined });
vi.stubGlobal('window', {
  addEventListener: vi.fn(),
});

const {
  _uint8ToBase64,
  _resolveAck,
  uploadFileChunked,
  sendSftpUploadCancel,
  CHUNK_SIZE,
} = await import('../connection.js');

// Access appState to wire up a mock WS
const { appState } = await import('../state.js');

describe('_uint8ToBase64', () => {
  it('encodes an empty array', () => {
    expect(_uint8ToBase64(new Uint8Array([]))).toBe('');
  });

  it('encodes a small array correctly', () => {
    // "Hello" in ASCII = [72, 101, 108, 108, 111]
    const bytes = new Uint8Array([72, 101, 108, 108, 111]);
    expect(_uint8ToBase64(bytes)).toBe(btoa('Hello'));
  });

  it('encodes a single byte', () => {
    const bytes = new Uint8Array([65]); // 'A'
    expect(_uint8ToBase64(bytes)).toBe(btoa('A'));
  });

  it('handles a large array (> 32KB block boundary)', () => {
    // Create a 40KB array to cross the 32KB block boundary
    const size = 40 * 1024;
    const bytes = new Uint8Array(size);
    for (let i = 0; i < size; i++) bytes[i] = i % 256;
    const result = _uint8ToBase64(bytes);
    // Verify by decoding back
    const decoded = Uint8Array.from(atob(result), (c) => c.charCodeAt(0));
    expect(decoded.length).toBe(size);
    for (let i = 0; i < size; i++) {
      expect(decoded[i]).toBe(i % 256);
    }
  });

  it('encodes binary data with all byte values 0-255', () => {
    const bytes = new Uint8Array(256);
    for (let i = 0; i < 256; i++) bytes[i] = i;
    const result = _uint8ToBase64(bytes);
    const decoded = Uint8Array.from(atob(result), (c) => c.charCodeAt(0));
    expect(decoded).toEqual(bytes);
  });
});

describe('_resolveAck', () => {
  it('is a callable function', () => {
    expect(typeof _resolveAck).toBe('function');
  });

  it('does not throw when called with an unknown requestId', () => {
    expect(() => _resolveAck('unknown-id', 0)).not.toThrow();
  });
});

describe('CHUNK_SIZE', () => {
  it('is 192 KB', () => {
    expect(CHUNK_SIZE).toBe(192 * 1024);
  });
});

describe('uploadFileChunked', () => {
  beforeEach(() => {
    wsSendSpy.mockClear();
    // Set up a mock WS on appState
    const mockWs = new WebSocket('ws://localhost:8081');
    mockWs.readyState = WebSocket.OPEN;
    mockWs.send = wsSendSpy;
    appState.ws = mockWs;
    appState.sshConnected = true;
  });

  it('throws when not connected', async () => {
    appState.sshConnected = false;
    const file = new File(['test'], 'test.txt');
    await expect(
      uploadFileChunked('/remote/path.txt', file, 'req-1', vi.fn()),
    ).rejects.toThrow('Not connected');
  });

  it('sends start message with correct fields', async () => {
    const file = new File(['hello world'], 'test.txt');

    // Start upload but resolve the initial ack immediately
    const uploadPromise = uploadFileChunked('/remote/path.txt', file, 'req-start', vi.fn());

    // The start message should have been sent
    expect(wsSendSpy).toHaveBeenCalledTimes(1);
    const startMsg = JSON.parse(wsSendSpy.mock.calls[0][0] as string) as Record<string, unknown>;
    expect(startMsg.type).toBe('sftp_upload_start');
    expect(startMsg.path).toBe('/remote/path.txt');
    expect(startMsg.size).toBe(file.size);
    expect(startMsg.requestId).toBe('req-start');
    expect(startMsg.fingerprint).toBe(`${String(file.size)}-test.txt`);

    // Resolve the initial ack (offset 0 = no resume)
    _resolveAck('req-start', 0);

    // Now chunks will be sent. Resolve acks for each chunk as they come.
    // File is small (11 bytes), so just one chunk.
    await vi.waitFor(() => {
      expect(wsSendSpy.mock.calls.length).toBeGreaterThanOrEqual(2);
    }, { timeout: 500 });

    // Resolve the chunk ack
    _resolveAck('req-start', 11);

    await uploadPromise;

    // Verify chunk message was sent
    const chunkMsg = JSON.parse(wsSendSpy.mock.calls[1][0] as string) as Record<string, unknown>;
    expect(chunkMsg.type).toBe('sftp_upload_chunk');
    expect(chunkMsg.requestId).toBe('req-start');

    // Verify end message was sent
    const endMsg = JSON.parse(wsSendSpy.mock.calls[2][0] as string) as Record<string, unknown>;
    expect(endMsg.type).toBe('sftp_upload_end');
    expect(endMsg.requestId).toBe('req-start');
  });

  it('calls onProgress with sent/total bytes', async () => {
    const content = 'hello world test data';
    const file = new File([content], 'progress.txt');
    const onProgress = vi.fn();

    const uploadPromise = uploadFileChunked('/remote/progress.txt', file, 'req-prog', onProgress);

    // Resolve initial ack
    _resolveAck('req-prog', 0);

    // Wait for chunk send
    await vi.waitFor(() => {
      expect(wsSendSpy.mock.calls.length).toBeGreaterThanOrEqual(2);
    }, { timeout: 500 });

    // Resolve chunk ack
    _resolveAck('req-prog', content.length);

    await uploadPromise;

    // onProgress should have been called with bytesSent and totalBytes
    expect(onProgress).toHaveBeenCalled();
    const lastCall = onProgress.mock.calls[onProgress.mock.calls.length - 1][0] as { bytesSent: number; totalBytes: number };
    expect(lastCall.totalBytes).toBe(file.size);
    expect(lastCall.bytesSent).toBe(file.size);
  });
});

describe('sendSftpUploadCancel', () => {
  beforeEach(() => {
    wsSendSpy.mockClear();
    const mockWs = new WebSocket('ws://localhost:8081');
    mockWs.readyState = WebSocket.OPEN;
    mockWs.send = wsSendSpy;
    appState.ws = mockWs;
    appState.sshConnected = true;
  });

  it('sends cancel message when connected', () => {
    sendSftpUploadCancel('req-cancel');
    expect(wsSendSpy).toHaveBeenCalledTimes(1);
    const msg = JSON.parse(wsSendSpy.mock.calls[0][0] as string) as Record<string, unknown>;
    expect(msg.type).toBe('sftp_upload_cancel');
    expect(msg.requestId).toBe('req-cancel');
  });

  it('does not send when disconnected', () => {
    appState.sshConnected = false;
    sendSftpUploadCancel('req-cancel-disc');
    expect(wsSendSpy).not.toHaveBeenCalled();
  });
});
