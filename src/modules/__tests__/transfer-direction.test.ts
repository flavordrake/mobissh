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
vi.stubGlobal('location', { hostname: 'localhost', hash: '', replace: vi.fn(), host: 'localhost:8081', pathname: '/', protocol: 'http:' });
vi.stubGlobal('requestAnimationFrame', (cb: () => void) => { cb(); return 0; });

let transferListEl: { innerHTML: string; querySelector: ReturnType<typeof vi.fn> };

vi.stubGlobal('document', {
  getElementById: (id: string) => {
    if (id === 'transferList') return transferListEl;
    return null;
  },
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: vi.fn(),
  visibilityState: 'visible',
  documentElement: {
    style: { setProperty: vi.fn() },
    dataset: {},
    classList: { toggle: vi.fn(), add: vi.fn(), remove: vi.fn() },
  },
  createElement: vi.fn(() => ({
    className: '',
    textContent: '',
    innerHTML: '',
    id: '',
    appendChild: vi.fn(),
    addEventListener: vi.fn(),
    querySelector: vi.fn(() => null),
    querySelectorAll: vi.fn(() => []),
    remove: vi.fn(),
    classList: { add: vi.fn(), remove: vi.fn(), toggle: vi.fn(), contains: vi.fn(() => false) },
    style: {},
    dataset: {},
  })),
  body: { appendChild: vi.fn(), classList: { add: vi.fn(), remove: vi.fn(), toggle: vi.fn() } },
  fonts: { ready: Promise.resolve() },
});

vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  visualViewport: { addEventListener: vi.fn(), height: 800, offsetTop: 0 },
  matchMedia: vi.fn(() => ({ matches: false, addEventListener: vi.fn() })),
  innerHeight: 800,
  outerHeight: 900,
  location: { hostname: 'localhost', hash: '', replace: vi.fn(), host: 'localhost:8081', pathname: '/', protocol: 'http:' },
});

vi.stubGlobal('navigator', {
  serviceWorker: { register: vi.fn(), ready: Promise.resolve({ showNotification: vi.fn() }) },
  clipboard: { writeText: vi.fn() },
});

vi.stubGlobal('Notification', { permission: 'granted' });
vi.stubGlobal('getComputedStyle', () => ({ getPropertyValue: () => '' }));
vi.stubGlobal('WebSocket', class { onopen = null; onclose = null; onmessage = null; onerror = null; send = vi.fn(); close = vi.fn(); readyState = 1; });
vi.stubGlobal('prompt', vi.fn());
vi.stubGlobal('confirm', vi.fn());
vi.stubGlobal('alert', vi.fn());
vi.stubGlobal('URL', class { constructor(public href: string) {} static createObjectURL = vi.fn(() => 'blob:test'); static revokeObjectURL = vi.fn(); });
vi.stubGlobal('Blob', class { constructor() {} });
vi.stubGlobal('FileReader', class { onload = null; readAsArrayBuffer = vi.fn(); result = new ArrayBuffer(0); });
vi.stubGlobal('ResizeObserver', class { observe = vi.fn(); unobserve = vi.fn(); disconnect = vi.fn(); });
vi.stubGlobal('MutationObserver', class { observe = vi.fn(); disconnect = vi.fn(); });
vi.stubGlobal('IntersectionObserver', class { observe = vi.fn(); disconnect = vi.fn(); });
vi.stubGlobal('MediaRecorder', class { start = vi.fn(); stop = vi.fn(); ondataavailable = null; onstop = null; state = 'inactive'; });
vi.stubGlobal('history', { pushState: vi.fn(), replaceState: vi.fn(), back: vi.fn() });
vi.stubGlobal('setTimeout', globalThis.setTimeout);
vi.stubGlobal('clearTimeout', globalThis.clearTimeout);
vi.stubGlobal('setInterval', globalThis.setInterval);
vi.stubGlobal('clearInterval', globalThis.clearInterval);

vi.mock('../connection.js', () => ({
  sendSSHInput: vi.fn(),
  disconnect: vi.fn(),
  reconnect: vi.fn(),
  sendSftpLs: vi.fn(),
  setSftpHandler: vi.fn(),
  sendSftpDownload: vi.fn(),
  sendSftpUpload: vi.fn(),
  sendSftpRename: vi.fn(),
  sendSftpDelete: vi.fn(),
  sendSftpRealpath: vi.fn(),
  uploadFileChunked: vi.fn(),
  sendSftpUploadCancel: vi.fn(),
}));

vi.mock('../recording.js', () => ({
  startRecording: vi.fn(),
  stopAndDownloadRecording: vi.fn(),
}));

vi.mock('../profiles.js', () => ({
  saveProfile: vi.fn(),
  connectFromProfile: vi.fn(),
  newConnection: vi.fn(),
}));

vi.mock('../ime.js', () => ({
  clearIMEPreview: vi.fn(),
}));

const { _transferRecords, _renderTransferList } = await import('../ui.js');

describe('Transfer direction indicator (#195)', () => {
  beforeEach(() => {
    _transferRecords.clear();
    transferListEl = { innerHTML: '', querySelector: vi.fn(() => null) };
  });

  it('upload record renders with up-arrow and upload CSS class', () => {
    _transferRecords.set('up-test-1', {
      name: 'config-backup.tar.gz',
      size: 1024,
      sent: 512,
      status: 'active',
      direction: 'upload',
    });
    _renderTransferList();

    expect(transferListEl.innerHTML).toContain('\u2191');
    expect(transferListEl.innerHTML).toContain('transfer-direction-upload');
    expect(transferListEl.innerHTML).toContain('config-backup.tar.gz');
  });

  it('download record renders with down-arrow and download CSS class', () => {
    _transferRecords.set('dl-test-1', {
      name: 'server-logs-2026-03.zip',
      size: 2048,
      sent: 0,
      status: 'active',
      direction: 'download',
    });
    _renderTransferList();

    expect(transferListEl.innerHTML).toContain('\u2193');
    expect(transferListEl.innerHTML).toContain('transfer-direction-download');
    expect(transferListEl.innerHTML).toContain('server-logs-2026-03.zip');
  });

  it('mixed uploads and downloads are visually distinguishable', () => {
    _transferRecords.set('up-mix-1', {
      name: 'deploy.sh',
      size: 100,
      sent: 100,
      status: 'done',
      direction: 'upload',
    });
    _transferRecords.set('dl-mix-1', {
      name: 'database-dump.sql',
      size: 200,
      sent: 200,
      status: 'done',
      direction: 'download',
    });
    _renderTransferList();

    expect(transferListEl.innerHTML).toContain('transfer-direction-upload');
    expect(transferListEl.innerHTML).toContain('transfer-direction-download');
    expect(transferListEl.innerHTML).toContain('\u2191');
    expect(transferListEl.innerHTML).toContain('\u2193');
  });

  it('direction arrow appears before filename in each item', () => {
    _transferRecords.set('up-order-1', {
      name: 'readme.md',
      size: 50,
      sent: 50,
      status: 'done',
      direction: 'upload',
    });
    _renderTransferList();

    const html = transferListEl.innerHTML;
    const arrowPos = html.indexOf('transfer-direction');
    const namePos = html.indexOf('transfer-item-name');
    expect(arrowPos).toBeLessThan(namePos);
  });
});
