/**
 * MobiSSH — Session recording (#54)
 *
 * Extracted from app.js as Phase 3 of modular refactor (#110).
 * Records SSH output in asciicast v2 format and triggers file download.
 *
 * asciicast v2 format: https://github.com/asciinema/asciinema/blob/master/doc/asciicast-v2.md
 * Header line: JSON object with version, width, height, timestamp, title
 * Event lines: JSON array [elapsed_seconds, "o", data]
 */

import type { RecordingDeps, AsciicastHeader } from './types.js';
import { appState } from './state.js';

// Injected dependency — set by initRecording()
let _toast = (_msg: string): void => {};
let _timerInterval: ReturnType<typeof setInterval> | null = null;

export function initRecording({ toast }: RecordingDeps): void {
  _toast = toast;
}

export function startRecording(): void {
  if (appState.recording) return;
  appState.recording = true;
  appState.recordingStartTime = Date.now();
  appState.recordingEvents = [];
  _updateRecordingUI();
  _toast('Recording started');
}

export function stopAndDownloadRecording(): void {
  if (!appState.recording) return;
  appState.recording = false;
  void _downloadCastFile();
  _updateRecordingUI();
}

async function _downloadCastFile(): Promise<void> {
  const header: AsciicastHeader = {
    version: 2,
    width: appState.terminal ? appState.terminal.cols : 220,
    height: appState.terminal ? appState.terminal.rows : 50,
    timestamp: Math.floor((appState.recordingStartTime ?? 0) / 1000),
    title: appState.currentProfile
      ? `${appState.currentProfile.username}@${appState.currentProfile.host}:${String(appState.currentProfile.port || 22)}`
      : 'MobiSSH Session',
  };
  const lines = [JSON.stringify(header), ...appState.recordingEvents.map((e) => JSON.stringify(e))].join('\n');
  // Filename: mobissh-YYYY-MM-DDTHH-MM-SS.cast
  const ts = new Date(appState.recordingStartTime ?? 0)
    .toISOString()
    .replace(/[:.]/g, '-')
    .slice(0, 19);
  const filename = `mobissh-${ts}.cast`;
  const blob = new Blob([lines + '\n'], { type: 'text/plain' });
  appState.recordingEvents = [];
  appState.recordingStartTime = null;

  const file = new File([blob], filename, { type: 'text/plain' });
  if ((navigator as Partial<Navigator>).canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file], title: filename });
    } catch (err) {
      if (err instanceof Error && err.name !== 'AbortError') {
        _toast('Download failed — try again');
      }
    }
  } else {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => { URL.revokeObjectURL(url); }, 1000);
  }
}

export function updateRecordingUI(): void {
  _updateRecordingUI();
}

function _formatElapsed(ms: number): string {
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  if (h > 0) return `${String(h)}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${String(m)}:${String(s).padStart(2, '0')}`;
}

function _updateTimer(): void {
  const timerEl = document.getElementById('recTimer');
  if (!timerEl || !appState.recordingStartTime) return;
  timerEl.textContent = _formatElapsed(Date.now() - appState.recordingStartTime);
}

function _updateRecordingUI(): void {
  const startBtn = document.getElementById('sessionRecordStartBtn');
  const stopBtn = document.getElementById('sessionRecordStopBtn');
  const indicator = document.getElementById('recIndicator');
  if (!startBtn || !stopBtn) return;
  startBtn.classList.toggle('hidden', appState.recording);
  stopBtn.classList.toggle('hidden', !appState.recording);
  indicator?.classList.toggle('hidden', !appState.recording);

  if (appState.recording) {
    _updateTimer();
    if (!_timerInterval) _timerInterval = setInterval(_updateTimer, 1000);
  } else {
    if (_timerInterval) { clearInterval(_timerInterval); _timerInterval = null; }
  }
}
