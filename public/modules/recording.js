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
import { appState } from './state.js';
// Injected dependency — set by initRecording()
let _toast = (_msg) => { };
export function initRecording({ toast }) {
    _toast = toast;
}
export function startRecording() {
    if (appState.recording)
        return;
    appState.recording = true;
    appState.recordingStartTime = Date.now();
    appState.recordingEvents = [];
    _updateRecordingUI();
    _toast('Recording started');
}
export function stopAndDownloadRecording() {
    if (!appState.recording)
        return;
    appState.recording = false;
    _downloadCastFile();
    _updateRecordingUI();
}
function _downloadCastFile() {
    const header = {
        version: 2,
        width: appState.terminal ? appState.terminal.cols : 220,
        height: appState.terminal ? appState.terminal.rows : 50,
        timestamp: Math.floor((appState.recordingStartTime ?? 0) / 1000),
        title: appState.currentProfile
            ? `${appState.currentProfile.username}@${appState.currentProfile.host}:${String(appState.currentProfile.port || 22)}`
            : 'MobiSSH Session',
    };
    const lines = [JSON.stringify(header), ...appState.recordingEvents.map((e) => JSON.stringify(e))].join('\n');
    const blob = new Blob([lines + '\n'], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    // Filename: mobissh-YYYY-MM-DDTHH-MM-SS.cast
    const ts = new Date(appState.recordingStartTime ?? 0)
        .toISOString()
        .replace(/[:.]/g, '-')
        .slice(0, 19);
    a.download = `mobissh-${ts}.cast`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    appState.recordingEvents = [];
    appState.recordingStartTime = null;
}
export function updateRecordingUI() {
    _updateRecordingUI();
}
function _updateRecordingUI() {
    const startBtn = document.getElementById('sessionRecordStartBtn');
    const stopBtn = document.getElementById('sessionRecordStopBtn');
    if (!startBtn || !stopBtn)
        return;
    startBtn.classList.toggle('hidden', appState.recording);
    stopBtn.classList.toggle('hidden', !appState.recording);
}
//# sourceMappingURL=recording.js.map