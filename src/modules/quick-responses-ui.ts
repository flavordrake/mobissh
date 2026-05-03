/**
 * modules/quick-responses-ui.ts — DOM bindings for #480 quick responses.
 *
 * Two surfaces:
 *  1. #quickResponseStrip — floating chip strip on the terminal panel. Tap
 *     a chip to send its stored text (and optionally `\r`) to the active
 *     session.
 *  2. The settings panel "Quick responses" subsection — list with inline
 *     edit + add form.
 *
 * The storage layer is in ./quick-responses.ts (pure helpers); this module
 * just renders + wires events.
 */

import { escHtml } from './constants.js';
import {
  getQuickResponses,
  getEnabledQuickResponses,
  addQuickResponse,
  updateQuickResponse,
  deleteQuickResponse,
  type QuickResponse,
} from './quick-responses.js';

/** Re-render the floating chip strip on the terminal panel. Hidden when
 *  there are no enabled entries. */
export function renderQuickResponseStrip(): void {
  const strip = document.getElementById('quickResponseStrip');
  if (!strip) return;
  const entries = getEnabledQuickResponses();
  if (entries.length === 0) {
    strip.classList.add('hidden');
    strip.innerHTML = '';
    return;
  }
  strip.classList.remove('hidden');
  strip.innerHTML = entries.map((q) => (
    `<button class="quick-response-chip" data-qr-id="${escHtml(q.id)}" type="button">${escHtml(q.label)}</button>`
  )).join('');
}

/** Re-render the settings-section list of all entries (enabled and disabled). */
function renderSettingsList(): void {
  const list = document.getElementById('quickResponseList');
  if (!list) return;
  const entries = getQuickResponses();
  if (entries.length === 0) {
    list.innerHTML = '<p class="hint">No quick responses yet. Add one below.</p>';
    return;
  }
  list.innerHTML = entries.map((q) => renderRow(q)).join('');
}

function renderRow(q: QuickResponse): string {
  return `<div class="quick-response-row" data-qr-id="${escHtml(q.id)}">
    <input class="qr-label-input" type="text" value="${escHtml(q.label)}" placeholder="Label" data-field="label" />
    <input class="qr-text-input" type="text" value="${escHtml(q.text)}" placeholder="Text to send" data-field="text" />
    <div class="quick-response-row-actions">
      <label class="quick-response-add-enter" title="Append Enter when sent">
        <input type="checkbox" data-field="appendEnter"${q.appendEnter ? ' checked' : ''} /> ↵
      </label>
      <label class="quick-response-add-enter" title="Enabled">
        <input type="checkbox" data-field="enabled"${q.enabled ? ' checked' : ''} /> on
      </label>
      <button class="item-btn danger" data-action="qr-delete" type="button">Delete</button>
    </div>
  </div>`;
}

interface QuickResponseDeps {
  /** Send text to the active terminal — typically connection.sendSSHInput. */
  sendInput: (text: string) => void;
  toast: (msg: string) => void;
}

export function initQuickResponses({ sendInput, toast }: QuickResponseDeps): void {
  // ── Chip strip: tap → send ──
  const strip = document.getElementById('quickResponseStrip');
  if (strip) {
    strip.addEventListener('click', (e) => {
      const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-qr-id]');
      if (!btn) return;
      const id = btn.dataset['qrId'];
      if (!id) return;
      const entry = getQuickResponses().find((q) => q.id === id);
      if (!entry || !entry.enabled) return;
      const payload = entry.appendEnter ? entry.text + '\r' : entry.text;
      sendInput(payload);
    });
  }

  // ── Settings list: edit / delete / toggle ──
  const list = document.getElementById('quickResponseList');
  if (list) {
    // Inline edits commit on `change` (text inputs blur or Enter; checkboxes click).
    list.addEventListener('change', (e) => {
      const input = e.target as HTMLInputElement;
      const row = input.closest<HTMLElement>('[data-qr-id]');
      if (!row) return;
      const id = row.dataset['qrId'];
      if (!id) return;
      const field = input.dataset['field'];
      if (field === 'label' || field === 'text') {
        updateQuickResponse(id, { [field]: input.value });
      } else if (field === 'appendEnter' || field === 'enabled') {
        updateQuickResponse(id, { [field]: input.checked });
      }
      renderQuickResponseStrip();
    });

    list.addEventListener('click', (e) => {
      const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-action="qr-delete"]');
      if (!btn) return;
      const row = btn.closest<HTMLElement>('[data-qr-id]');
      const id = row?.dataset['qrId'];
      if (!id) return;
      deleteQuickResponse(id);
      renderSettingsList();
      renderQuickResponseStrip();
      toast('Quick response deleted');
    });
  }

  // ── Add form ──
  const addBtn = document.getElementById('quickResponseAddBtn');
  if (addBtn) {
    addBtn.addEventListener('click', () => {
      const labelEl = document.getElementById('quickResponseAddLabel') as HTMLInputElement | null;
      const textEl = document.getElementById('quickResponseAddText') as HTMLInputElement | null;
      const enterEl = document.getElementById('quickResponseAddAppendEnter') as HTMLInputElement | null;
      const label = labelEl?.value.trim() ?? '';
      const text = textEl?.value ?? '';
      if (!label || !text) {
        toast('Both label and text are required');
        return;
      }
      addQuickResponse(label, text, enterEl?.checked ?? true);
      if (labelEl) labelEl.value = '';
      if (textEl) textEl.value = '';
      if (enterEl) enterEl.checked = true;
      renderSettingsList();
      renderQuickResponseStrip();
    });
  }

  // Initial paint.
  renderSettingsList();
  renderQuickResponseStrip();
}
