/**
 * modules/pattern-links-ui.ts — Settings panel UI for pattern rules (#478).
 *
 * Renders the rule list as inline-editable rows; new rules added via the
 * form below the list. Storage in pattern-links.ts.
 */

import { escHtml } from './constants.js';
import {
  getPatternRules,
  addPatternRule,
  updatePatternRule,
  deletePatternRule,
} from './pattern-links.js';

export function initPatternLinksUI(opts: { toast: (msg: string) => void }): void {
  const { toast } = opts;
  const list = document.getElementById('patternRulesList');
  if (!list) return;

  function render(): void {
    const rules = getPatternRules();
    if (rules.length === 0) {
      list!.innerHTML = '<p class="settings-section-help">No rules yet. Add one below.</p>';
      return;
    }
    list!.innerHTML = rules.map((r) => `
      <div class="pattern-rule-row" data-id="${escHtml(r.id)}">
        <div class="pattern-rule-row-head">
          <input type="text" class="pattern-rule-name" data-field="name" value="${escHtml(r.name)}" placeholder="Name" />
          <label class="toggle pattern-rule-enabled" aria-label="Enable rule">
            <input type="checkbox" data-field="enabled"${r.enabled ? ' checked' : ''} />
            <span class="toggle-slider toggle-slider-accent"></span>
          </label>
          <button class="icon-btn pattern-rule-delete" data-action="delete" aria-label="Delete rule">✕</button>
        </div>
        <label class="pattern-rule-label">Pattern</label>
        <input type="text" class="pattern-rule-pattern" data-field="pattern" value="${escHtml(r.pattern)}" autocapitalize="off" autocorrect="off" spellcheck="false" />
        <label class="pattern-rule-label">URL template</label>
        <input type="text" class="pattern-rule-url" data-field="urlTemplate" value="${escHtml(r.urlTemplate)}" autocapitalize="off" autocorrect="off" spellcheck="false" />
        <label class="pattern-rule-label">Host glob</label>
        <input type="text" class="pattern-rule-hostglob" data-field="hostGlob" value="${escHtml(r.hostGlob)}" autocapitalize="off" autocorrect="off" spellcheck="false" />
      </div>
    `).join('');
  }

  list.addEventListener('change', (e) => {
    const target = e.target as HTMLInputElement;
    const row = target.closest<HTMLElement>('.pattern-rule-row');
    if (!row) return;
    const id = row.dataset['id'];
    const field = target.dataset['field'];
    if (!id || !field) return;
    if (field === 'enabled') {
      updatePatternRule(id, { enabled: target.checked });
    } else if (field === 'name' || field === 'pattern' || field === 'urlTemplate' || field === 'hostGlob') {
      updatePatternRule(id, { [field]: target.value } as Partial<{ name: string; pattern: string; urlTemplate: string; hostGlob: string }>);
    }
  });

  list.addEventListener('click', (e) => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-action]');
    if (!btn) return;
    const row = btn.closest<HTMLElement>('.pattern-rule-row');
    const id = row?.dataset['id'];
    if (!id) return;
    if (btn.dataset['action'] === 'delete') {
      deletePatternRule(id);
      render();
    }
  });

  const addBtn = document.getElementById('addPatternRuleBtn');
  addBtn?.addEventListener('click', () => {
    const nameEl = document.getElementById('patternRuleName') as HTMLInputElement | null;
    const patternEl = document.getElementById('patternRulePattern') as HTMLInputElement | null;
    const urlEl = document.getElementById('patternRuleUrl') as HTMLInputElement | null;
    const hostEl = document.getElementById('patternRuleHostGlob') as HTMLInputElement | null;
    const name = nameEl?.value.trim() ?? '';
    const pattern = patternEl?.value.trim() ?? '';
    const urlTemplate = urlEl?.value.trim() ?? '';
    const hostGlob = hostEl?.value.trim() ?? '';
    if (!pattern || !urlTemplate) {
      toast('Pattern and URL template are required.');
      return;
    }
    try { new RegExp(pattern); } catch {
      toast('Invalid regex pattern.');
      return;
    }
    addPatternRule({ name, pattern, urlTemplate, hostGlob });
    if (nameEl) nameEl.value = '';
    if (patternEl) patternEl.value = '';
    if (urlEl) urlEl.value = '';
    if (hostEl) hostEl.value = '';
    render();
  });

  render();
}
