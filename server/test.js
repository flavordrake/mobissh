'use strict';

/**
 * server/test.js — unit tests for server helper functions
 *
 * Run with: npm test  (from the server/ directory)
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Readable, Writable } = require('stream');

const { rewriteManifest, handleSftpMessage, isPrivateIp, isCgnatIp, resumableUploads } = require('./index.js');

test('rewriteManifest: sets id="mobissh"', () => {
  const input = Buffer.from(JSON.stringify({ name: 'MobiSSH', start_url: '/' }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.id, 'mobissh');
});

test('rewriteManifest: sets start_url="./#connect"', () => {
  const input = Buffer.from(JSON.stringify({ start_url: '/' }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.start_url, './#connect');
});

test('rewriteManifest: sets scope="./"', () => {
  const input = Buffer.from(JSON.stringify({ name: 'MobiSSH' }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.scope, './');
});

test('rewriteManifest: preserves other manifest fields', () => {
  const input = Buffer.from(JSON.stringify({
    name: 'MobiSSH',
    theme_color: '#1a1a2e',
    icons: [{ src: 'icon-192.svg', sizes: '192x192' }],
  }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.name, 'MobiSSH');
  assert.equal(result.theme_color, '#1a1a2e');
  assert.deepEqual(result.icons, [{ src: 'icon-192.svg', sizes: '192x192' }]);
});

test('rewriteManifest: overwrites existing id', () => {
  const input = Buffer.from(JSON.stringify({ id: 'old-id', name: 'MobiSSH' }));
  const result = JSON.parse(rewriteManifest(input));
  assert.equal(result.id, 'mobissh');
});

// ─── handleSftpMessage tests ──────────────────────────────────────────────────

test('handleSftpMessage: sftp_ls returns entries with correct shape', () => {
  const results = [];
  const mockSftp = {
    readdir: (path, cb) => cb(null, [
      { filename: 'file.txt', attrs: { isDirectory: () => false, size: 100, mtime: 1000 } },
      { filename: 'subdir', attrs: { isDirectory: () => true, size: 0, mtime: 2000 } },
    ]),
  };
  handleSftpMessage({ type: 'sftp_ls', path: '/', requestId: '1' }, mockSftp, (msg) => results.push(msg));
  assert.equal(results.length, 1);
  assert.equal(results[0].type, 'sftp_ls_result');
  assert.equal(results[0].requestId, '1');
  assert.deepEqual(results[0].entries[0], { name: 'file.txt', isDir: false, size: 100, mtime: 1000 });
  assert.deepEqual(results[0].entries[1], { name: 'subdir', isDir: true, size: 0, mtime: 2000 });
});

test('handleSftpMessage: sftp_ls error returns sftp_error', () => {
  const results = [];
  const mockSftp = { readdir: (path, cb) => cb(new Error('Permission denied')) };
  handleSftpMessage({ type: 'sftp_ls', path: '/root', requestId: '2' }, mockSftp, (msg) => results.push(msg));
  assert.equal(results.length, 1);
  assert.equal(results[0].type, 'sftp_error');
  assert.equal(results[0].requestId, '2');
  assert.equal(results[0].message, 'Permission denied');
});

test('handleSftpMessage: sftp_download returns base64 data', (t, done) => {
  const content = Buffer.from('hello world');
  const mockSftp = {
    createReadStream: () => {
      const rs = new Readable({ read() {} });
      process.nextTick(() => { rs.push(content); rs.push(null); });
      return rs;
    },
  };
  handleSftpMessage({ type: 'sftp_download', path: '/file.txt', requestId: '3' }, mockSftp, (msg) => {
    assert.equal(msg.type, 'sftp_download_result');
    assert.equal(msg.requestId, '3');
    assert.equal(msg.data, content.toString('base64'));
    done();
  });
});

test('handleSftpMessage: sftp_download error returns sftp_error', (t, done) => {
  const mockSftp = {
    createReadStream: () => {
      const rs = new Readable({ read() {} });
      process.nextTick(() => rs.destroy(new Error('No such file')));
      return rs;
    },
  };
  handleSftpMessage({ type: 'sftp_download', path: '/missing', requestId: '4' }, mockSftp, (msg) => {
    assert.equal(msg.type, 'sftp_error');
    assert.equal(msg.requestId, '4');
    assert.equal(msg.message, 'No such file');
    done();
  });
});

test('handleSftpMessage: sftp_upload writes base64-decoded data', (t, done) => {
  const content = 'hello world';
  const encoded = Buffer.from(content).toString('base64');
  let writtenData = null;
  const mockSftp = {
    createWriteStream: () => new Writable({
      write(chunk, _enc, cb) { writtenData = chunk; cb(); },
    }),
  };
  handleSftpMessage({ type: 'sftp_upload', path: '/out.txt', data: encoded, requestId: '5' }, mockSftp, (msg) => {
    assert.equal(msg.type, 'sftp_upload_result');
    assert.equal(msg.requestId, '5');
    assert.equal(msg.ok, true);
    assert.deepEqual(writtenData, Buffer.from(content));
    done();
  });
});

test('handleSftpMessage: sftp_upload rejects non-string data', () => {
  const results = [];
  const mockSftp = { createWriteStream: () => new Writable({ write(c, e, cb) { cb(); } }) };
  handleSftpMessage({ type: 'sftp_upload', path: '/out.txt', data: 123, requestId: '6' }, mockSftp, (msg) => results.push(msg));
  assert.equal(results.length, 1);
  assert.equal(results[0].type, 'sftp_error');
  assert.equal(results[0].requestId, '6');
});

test('handleSftpMessage: sftp_stat returns stat info', () => {
  const results = [];
  const mockSftp = {
    stat: (path, cb) => cb(null, { isDirectory: () => false, size: 512, mtime: 1700000000 }),
  };
  handleSftpMessage({ type: 'sftp_stat', path: '/file.txt', requestId: '7' }, mockSftp, (msg) => results.push(msg));
  assert.equal(results.length, 1);
  assert.equal(results[0].type, 'sftp_stat_result');
  assert.equal(results[0].requestId, '7');
  assert.deepEqual(results[0].stat, { isDir: false, size: 512, mtime: 1700000000 });
});

test('handleSftpMessage: sftp_stat error returns sftp_error', () => {
  const results = [];
  const mockSftp = { stat: (path, cb) => cb(new Error('Not found')) };
  handleSftpMessage({ type: 'sftp_stat', path: '/missing', requestId: '8' }, mockSftp, (msg) => results.push(msg));
  assert.equal(results.length, 1);
  assert.equal(results[0].type, 'sftp_error');
  assert.equal(results[0].requestId, '8');
  assert.equal(results[0].message, 'Not found');
});

// ─── isPrivateIp tests (issue #84) ────────────────────────────────────────────

test('isPrivateIp: 127.0.0.1 is private (loopback)', () => {
  assert.equal(isPrivateIp('127.0.0.1'), true);
});

test('isPrivateIp: 127.255.255.255 is private (loopback /8)', () => {
  assert.equal(isPrivateIp('127.255.255.255'), true);
});

test('isPrivateIp: 0.0.0.0 is private (unspecified)', () => {
  assert.equal(isPrivateIp('0.0.0.0'), true);
});

test('isPrivateIp: 10.0.0.1 is private (RFC-1918 10/8)', () => {
  assert.equal(isPrivateIp('10.0.0.1'), true);
});

test('isPrivateIp: 10.255.255.255 is private (RFC-1918 10/8 boundary)', () => {
  assert.equal(isPrivateIp('10.255.255.255'), true);
});

test('isPrivateIp: 172.16.0.1 is private (RFC-1918 172.16/12)', () => {
  assert.equal(isPrivateIp('172.16.0.1'), true);
});

test('isPrivateIp: 172.31.255.255 is private (RFC-1918 172.16/12 boundary)', () => {
  assert.equal(isPrivateIp('172.31.255.255'), true);
});

test('isPrivateIp: 172.15.255.255 is NOT private (just outside 172.16/12)', () => {
  assert.equal(isPrivateIp('172.15.255.255'), false);
});

test('isPrivateIp: 172.32.0.0 is NOT private (just outside 172.16/12)', () => {
  assert.equal(isPrivateIp('172.32.0.0'), false);
});

test('isPrivateIp: 192.168.1.1 is private (RFC-1918 192.168/16)', () => {
  assert.equal(isPrivateIp('192.168.1.1'), true);
});

test('isPrivateIp: 169.254.1.1 is private (link-local)', () => {
  assert.equal(isPrivateIp('169.254.1.1'), true);
});

test('isPrivateIp: 100.64.0.1 is private (CGNAT)', () => {
  assert.equal(isPrivateIp('100.64.0.1'), true);
});

test('isPrivateIp: 100.127.255.255 is private (CGNAT boundary)', () => {
  assert.equal(isPrivateIp('100.127.255.255'), true);
});

test('isPrivateIp: 100.128.0.0 is NOT private (just outside CGNAT)', () => {
  assert.equal(isPrivateIp('100.128.0.0'), false);
});

test('isPrivateIp: 8.8.8.8 is NOT private (public IP)', () => {
  assert.equal(isPrivateIp('8.8.8.8'), false);
});

test('isPrivateIp: 1.1.1.1 is NOT private (public IP)', () => {
  assert.equal(isPrivateIp('1.1.1.1'), false);
});

test('isPrivateIp: ::1 is private (IPv6 loopback)', () => {
  assert.equal(isPrivateIp('::1'), true);
});

test('isPrivateIp: :: is private (IPv6 unspecified)', () => {
  assert.equal(isPrivateIp('::'), true);
});

test('isPrivateIp: fc00::1 is private (IPv6 ULA)', () => {
  assert.equal(isPrivateIp('fc00::1'), true);
});

test('isPrivateIp: fd12:3456::1 is private (IPv6 ULA fd)', () => {
  assert.equal(isPrivateIp('fd12:3456::1'), true);
});

test('isPrivateIp: fe80::1 is private (IPv6 link-local)', () => {
  assert.equal(isPrivateIp('fe80::1'), true);
});

test('isPrivateIp: 2001:db8::1 is NOT private (public IPv6)', () => {
  assert.equal(isPrivateIp('2001:db8::1'), false);
});

test('isPrivateIp: ::ffff:127.0.0.1 is private (IPv4-mapped loopback)', () => {
  assert.equal(isPrivateIp('::ffff:127.0.0.1'), true);
});

test('isPrivateIp: ::ffff:10.0.0.1 is private (IPv4-mapped RFC-1918)', () => {
  assert.equal(isPrivateIp('::ffff:10.0.0.1'), true);
});

test('isPrivateIp: ::ffff:8.8.8.8 is NOT private (IPv4-mapped public)', () => {
  assert.equal(isPrivateIp('::ffff:8.8.8.8'), false);
});

// ─── isCgnatIp tests (issue #91) ──────────────────────────────────────────────

test('isCgnatIp: 100.64.0.1 is CGNAT', () => {
  assert.equal(isCgnatIp('100.64.0.1'), true);
});

test('isCgnatIp: 100.127.255.255 is CGNAT (boundary)', () => {
  assert.equal(isCgnatIp('100.127.255.255'), true);
});

test('isCgnatIp: 100.63.255.255 is NOT CGNAT (just below range)', () => {
  assert.equal(isCgnatIp('100.63.255.255'), false);
});

test('isCgnatIp: 100.128.0.0 is NOT CGNAT (just above range)', () => {
  assert.equal(isCgnatIp('100.128.0.0'), false);
});

test('isCgnatIp: 10.0.0.1 is NOT CGNAT', () => {
  assert.equal(isCgnatIp('10.0.0.1'), false);
});

test('isCgnatIp: 192.168.1.1 is NOT CGNAT', () => {
  assert.equal(isCgnatIp('192.168.1.1'), false);
});

// ─── TS_SERVE CGNAT exemption tests (issue #91) ───────────────────────────────
// These tests verify the connect()-level logic by directly testing the
// isPrivateIp + isCgnatIp combination that the connect() function uses.

test('CGNAT allowed when TS_SERVE=1: 100.64.x.x is still private via isPrivateIp', () => {
  // isPrivateIp still classifies CGNAT as private — the exemption lives in connect()
  assert.equal(isPrivateIp('100.64.100.5'), true);
});

test('CGNAT exemption logic: TS_SERVE=1 allows 100.64.x.x', () => {
  // Simulate the connect() guard: blocked = isPrivateIp && !(tsMode && isCgnat)
  const ip = '100.64.100.5';
  const tsMode = true;
  const blocked = isPrivateIp(ip) && !(tsMode && isCgnatIp(ip));
  assert.equal(blocked, false);
});

test('CGNAT exemption logic: no TS_SERVE blocks 100.64.x.x', () => {
  const ip = '100.64.100.5';
  const tsMode = false;
  const blocked = isPrivateIp(ip) && !(tsMode && isCgnatIp(ip));
  assert.equal(blocked, true);
});

test('CGNAT exemption logic: TS_SERVE=1 still blocks 192.168.x.x', () => {
  const ip = '192.168.1.1';
  const tsMode = true;
  const blocked = isPrivateIp(ip) && !(tsMode && isCgnatIp(ip));
  assert.equal(blocked, true);
});

test('CGNAT exemption logic: TS_SERVE=1 still blocks 127.0.0.1', () => {
  const ip = '127.0.0.1';
  const tsMode = true;
  const blocked = isPrivateIp(ip) && !(tsMode && isCgnatIp(ip));
  assert.equal(blocked, true);
});

test('CGNAT exemption logic: TS_SERVE=1 still blocks 10.0.0.1', () => {
  const ip = '10.0.0.1';
  const tsMode = true;
  const blocked = isPrivateIp(ip) && !(tsMode && isCgnatIp(ip));
  assert.equal(blocked, true);
});

// Cross-session upload hijack prevention (issue #241)

test('sftp_upload_start: same connectionId allows resume (#241)', () => {
  resumableUploads.clear();
  const results = [];
  const openUploads = new Map();
  const connId = 'conn-same-1';
  const mockStream = new Writable({ write(c, e, cb) { cb(); } });
  // Pre-populate a resumable entry as if a previous connection created it
  resumableUploads.set('fp-same', {
    stream: mockStream, offset: 500, path: '/upload.bin',
    fingerprint: 'fp-same', requestId: 'old-req', sftp: {}, ttlTimer: null,
    connectionId: connId,
  });
  const mockSftp = { createWriteStream: () => mockStream };
  handleSftpMessage(
    { type: 'sftp_upload_start', path: '/upload.bin', size: 1000, fingerprint: 'fp-same', requestId: 'new-req' },
    mockSftp, (msg) => results.push(msg), openUploads, null, connId,
  );
  assert.equal(results.length, 1);
  assert.equal(results[0].type, 'sftp_upload_ack');
  assert.equal(results[0].offset, 500, 'should resume from existing offset');
  assert.equal(results[0].requestId, 'new-req');
  resumableUploads.clear();
});

test('sftp_upload_start: different connectionId rejects resume (#241)', () => {
  resumableUploads.clear();
  const results = [];
  const openUploads = new Map();
  const attackerConnId = 'conn-attacker';
  const victimConnId = 'conn-victim';
  const mockStream = new Writable({ write(c, e, cb) { cb(); } });
  // Pre-populate a resumable entry owned by victim
  resumableUploads.set('fp-hijack', {
    stream: mockStream, offset: 500, path: '/upload.bin',
    fingerprint: 'fp-hijack', requestId: 'victim-req', sftp: {}, ttlTimer: null,
    connectionId: victimConnId,
  });
  const freshStream = new Writable({ write(c, e, cb) { cb(); } });
  const mockSftp = { createWriteStream: () => freshStream };
  handleSftpMessage(
    { type: 'sftp_upload_start', path: '/upload.bin', size: 1000, fingerprint: 'fp-hijack', requestId: 'atk-req' },
    mockSftp, (msg) => results.push(msg), openUploads, null, attackerConnId,
  );
  assert.equal(results.length, 1);
  assert.equal(results[0].type, 'sftp_upload_ack');
  assert.equal(results[0].offset, 0, 'should start fresh, not resume from 500');
  assert.equal(results[0].requestId, 'atk-req');
  // The fresh entry should have the attacker's connectionId
  const entry = resumableUploads.get('fp-hijack');
  assert.equal(entry.connectionId, attackerConnId);
  resumableUploads.clear();
});
