'use strict';

/**
 * server/test.js — unit tests for server helper functions
 *
 * Run with: npm test  (from the server/ directory)
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Readable, Writable } = require('stream');

const { rewriteManifest, handleSftpMessage } = require('./index.js');

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
