import { describe, it, expect } from 'vitest';
import type { ServerMessage } from '../types.js';

/**
 * Type-level tests for chunked download message types.
 *
 * These verify that the ServerMessage discriminated union includes
 * sftp_download_meta, sftp_download_chunk, and sftp_download_end
 * with the correct field shapes. A compilation failure here means
 * the types are out of sync with the server protocol.
 */

describe('ServerMessage download types', () => {
  it('sftp_download_meta has requestId and size fields', () => {
    const msg: ServerMessage = {
      type: 'sftp_download_meta',
      requestId: 'dl-1',
      size: 1024,
    };
    expect(msg.type).toBe('sftp_download_meta');
    if (msg.type === 'sftp_download_meta') {
      expect(msg.requestId).toBe('dl-1');
      expect(msg.size).toBe(1024);
    }
  });

  it('sftp_download_chunk has requestId, offset, and data fields', () => {
    const msg: ServerMessage = {
      type: 'sftp_download_chunk',
      requestId: 'dl-2',
      offset: 0,
      data: 'aGVsbG8=', // base64
    };
    expect(msg.type).toBe('sftp_download_chunk');
    if (msg.type === 'sftp_download_chunk') {
      expect(msg.requestId).toBe('dl-2');
      expect(msg.offset).toBe(0);
      expect(msg.data).toBe('aGVsbG8=');
    }
  });

  it('sftp_download_end has requestId field', () => {
    const msg: ServerMessage = {
      type: 'sftp_download_end',
      requestId: 'dl-3',
    };
    expect(msg.type).toBe('sftp_download_end');
    if (msg.type === 'sftp_download_end') {
      expect(msg.requestId).toBe('dl-3');
    }
  });

  it('sftp_download_result has requestId and optional data/ok/error', () => {
    // Full download (non-chunked) result
    const msg: ServerMessage = {
      type: 'sftp_download_result',
      requestId: 'dl-4',
      data: 'dGVzdA==',
    };
    expect(msg.type).toBe('sftp_download_result');

    // Error variant
    const errMsg: ServerMessage = {
      type: 'sftp_download_result',
      requestId: 'dl-5',
      ok: false,
      error: 'No such file',
    };
    expect(errMsg.type).toBe('sftp_download_result');
  });

  it('sftp_upload_ack has requestId and offset fields', () => {
    // Included here since it is part of the chunked transfer protocol
    const msg: ServerMessage = {
      type: 'sftp_upload_ack',
      requestId: 'up-1',
      offset: 4096,
    };
    expect(msg.type).toBe('sftp_upload_ack');
    if (msg.type === 'sftp_upload_ack') {
      expect(msg.requestId).toBe('up-1');
      expect(msg.offset).toBe(4096);
    }
  });
});
