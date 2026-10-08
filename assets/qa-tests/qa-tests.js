'use strict';
(() => {
  const STORAGE_KEY = 'bt_qa_run_v1';
  const APP_ID = 'betshuva-operational-qa';
  const STATUSES = {
    'not-run': 'טרם נבדק', passed: 'עבר', failed: 'נכשל',
    blocked: 'חסום', 'not-applicable': 'לא ישים',
  };
  const ROLES = {
    user: 'משתמש', groupAdmin: 'מנהל קבוצה', adminView: 'מנהל · צפייה',
    adminEdit: 'מנהל · עריכה', mailOwner: 'בעל חשבון דואר מורשה', tester: 'בודק',
  };
  const PLATFORMS = { web: 'דפדפן', android: 'Android' };
  const $ = id => document.getElementById(id);
  const state = { catalog: null, run: null, results: new Map(), cards: new Map(), storageAvailable: true };
  let saveTimer;
  let searchTimer;
  let noticeTimer;

  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function today() {
    const date = new Date();
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
  }
  function blankResult(id) { return { id, status: 'not-run', notes: '', issueId: '', updatedAt: '' }; }
  function defaultRun() {
    return { testedVersion: `${state.catalog.appVersion}+${state.catalog.buildNumber}`, date: today(), tester: '' };
  }
  function notify(message, warning = false, persistent = false) {
    clearTimeout(noticeTimer);
    $('notice').textContent = message;
    $('notice').className = warning ? 'notice warning' : 'notice';
    $('notice').hidden = false;
    if (!persistent) noticeTimer = setTimeout(() => { $('notice').hidden = true; }, 9000);
  }
  function warnStorage() {
    state.storageAvailable = false;
    $('storage-notice').textContent = 'השמירה בדפדפן אינה זמינה. אפשר להמשיך לבדוק, אך יש לייצא את התוצאות לפני סגירת הדף כדי לשמור אותן.';
    $('storage-notice').hidden = false;
    $('save-status').textContent = 'שמירה בזיכרון בלבד';
  }
  function normalize(text) {
    return String(text).normalize('NFKC').toLocaleLowerCase('he').replace(/[\u0591-\u05c7]/g, '').replace(/[׳’‘]/g, "'");
  }
  function documentForExport() {
    return {
      schemaVersion: 1, app: APP_ID, exportedAt: new Date().toISOString(),
      catalog: {
        version: state.catalog.catalogVersion, appVersion: state.catalog.appVersion,
        buildNumber: state.catalog.buildNumber, webBuildId: state.catalog.webBuildId,
      },
      run: { ...state.run },
      results: state.catalog.items.map(item => ({ ...state.results.get(item.id) })),
    };
  }
  function save() {
    clearTimeout(saveTimer);
    if (!state.catalog || !state.storageAvailable) return;
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(documentForExport()));
      $('save-status').textContent = 'נשמר בדפדפן';
    } catch (_) { warnStorage(); }
  }
  function scheduleSave() {
    if (state.storageAvailable) $('save-status').textContent = 'שומר…';
    clearTimeout(saveTimer);
    saveTimer = setTimeout(save, 350);
  }
  function validateImport(doc) {
    if (!doc || typeof doc !== 'object' || Array.isArray(doc) || doc.schemaVersion !== 1 || doc.app !== APP_ID) {
      throw new Error('זה אינו קובץ תוצאות של דף הבדיקות.');
    }
    if (!doc.run || typeof doc.run !== 'object' || Array.isArray(doc.run)) throw new Error('פרטי ריצת הבדיקה חסרים.');
    const string = (value, limit, field) => {
      if (typeof value !== 'string' || value.length > limit) throw new Error(`ערך לא תקין בשדה ${field}.`);
      return value;
    };
    const run = {
      testedVersion: string(doc.run.testedVersion, 100, 'גרסה'),
      date: string(doc.run.date, 10, 'תאריך'), tester: string(doc.run.tester, 120, 'בודק'),
    };
    if (run.date && !/^\d{4}-\d{2}-\d{2}$/.test(run.date)) throw new Error('תאריך הבדיקה אינו תקין.');
    if (run.date && (Number.isNaN(Date.parse(`${run.date}T12:00:00Z`)) || new Date(`${run.date}T12:00:00Z`).toISOString().slice(0, 10) !== run.date)) {
      throw new Error('תאריך הבדיקה אינו תקין.');
    }
    if (!Array.isArray(doc.results) || doc.results.length > state.catalog.items.length) throw new Error('רשימת התוצאות אינה תקינה.');
    const ids = new Set(state.catalog.items.map(item => item.id));
    const results = new Map(state.catalog.items.map(item => [item.id, blankResult(item.id)]));
    const seen = new Set();
    for (const row of doc.results) {
      if (!row || typeof row !== 'object' || Array.isArray(row) || !ids.has(row.id) || seen.has(row.id)) throw new Error('יש מזהה בדיקה לא מוכר או כפול בקובץ.');
      if (!Object.hasOwn(STATUSES, row.status)) throw new Error(`תוצאה לא תקינה בבדיקה ${row.id}.`);
      const updatedAt = string(row.updatedAt === undefined ? '' : row.updatedAt, 32, 'מועד עדכון');
      if (updatedAt && (!/^\d{4}-\d{2}-\d{2}T/.test(updatedAt) || Number.isNaN(Date.parse(updatedAt)))) throw new Error('מועד עדכון אינו תקין.');
      results.set(row.id, {
        id: row.id, status: row.status, notes: string(row.notes, 8000, 'הערות'),
        issueId: string(row.issueId, 160, 'מזהה פנייה'), updatedAt,
      });
      seen.add(row.id);
    }
    return { run, results };
  }
  function restore() {
    state.run = defaultRun();
    state.results = new Map(state.catalog.items.map(item => [item.id, blankResult(item.id)]));
    try {
      const previous = localStorage.getItem(STORAGE_KEY);
      if (previous) {
        try {
          const restored = validateImport(JSON.parse(previous));
          state.run = restored.run;
          state.results = restored.results;
        } catch (_) {
          notify('לא ניתן לקרוא את התוצאות שנשמרו. הן נשארו באחסון ללא שינוי; מוצגת ריצה חדשה. יש לייצא או לאפס לפני שמירת תוצאות חדשות.', true, true);
          warnStorage();
        }
      } else {
        // A browser can allow reads but reject writes (private mode or quota).
        localStorage.setItem(STORAGE_KEY, JSON.stringify(documentForExport()));
      }
      if (state.storageAvailable) $('save-status').textContent = 'נשמר בדפדפן';
    } catch (_) { warnStorage(); }
  }
  function displayRun() {
    $('tested-version').value = state.run.testedVersion;
    $('run-date').value = state.run.date;
    $('tester').value = state.run.tester;
  }
  function addOptions(select, options) {
    for (const [value, label] of options) {
      const option = element('option', label); option.value = value; select.append(option);
    }
  }
  function describeNote(value) {
    return typeof value === 'string' ? value : `${value.title || value.feature || ''}${value.reason ? ` — ${value.reason}` : ''}`;
  }
  function fillList(id, values) { $(id).replaceChildren(...values.map(value => element('li', describeNote(value)))); }
  function populateCatalog() {
    const catalog = state.catalog;
    $('catalog-baseline').textContent = `בסיס הקטלוג: ${catalog.appVersion}+${catalog.buildNumber} · מיפוי ${catalog.catalogVersion} · Web ${catalog.webBuildId}`;
    addOptions($('category-filter'), [...new Set(catalog.items.map(item => item.category))].sort((a, b) => a.localeCompare(b, 'he')).map(value => [value, value]));
    addOptions($('role-filter'), Object.entries(ROLES).filter(([role]) => catalog.items.some(item => item.role === role)));
    addOptions($('status-filter'), Object.entries(STATUSES));
    fillList('test-accounts', catalog.testAccounts || []);
    fillList('cross-checks', catalog.commonCrossChecks || []);
    fillList('catalog-notes', catalog.notes || []);
    fillList('catalog-excluded', catalog.excluded || []);
    $('catalog-guidance').hidden = false;
    const fragment = document.createDocumentFragment();
    for (const item of catalog.items) {
      item.searchText = normalize([item.id, item.category, item.title, item.preconditions, item.expected, item.note, ...item.steps, ...item.variants].join(' '));
      const card = element('details', undefined, 'test-card'); card.dataset.id = item.id;
      const summary = element('summary');
      const main = element('span', undefined, 'summary-main');
      const marker = element('span', undefined, 'expand-marker'); marker.setAttribute('aria-hidden', 'true');
      const titleBox = element('span');
      titleBox.append(element('span', item.title, 'test-title'));
      const meta = element('span', undefined, 'test-meta');
      meta.append(element('span', item.id, 'test-id'), element('span', item.category), element('span', item.platforms.map(p => PLATFORMS[p] || p).join(' / ')), element('span', ROLES[item.role] || item.role));
      if (item.kind === 'workflow') meta.append(element('span', 'תרחיש משולב'));
      if (item.availability === 'conditional') meta.append(element('span', 'נדרשים תנאים נוספים'));
      titleBox.append(meta); main.append(marker, titleBox);
      const badge = element('span', undefined, 'status-label');
      summary.append(main, badge); card.append(summary);
      card.addEventListener('toggle', () => { if (card.open && !card.dataset.populated) populateBody(card, item); });
      state.cards.set(item.id, { card, badge });
      updateBadge(item.id); fragment.append(card);
    }
    $('test-list').replaceChildren(fragment);
    $('test-list').setAttribute('aria-busy', 'false');
    renderCounts(); applyFilters();
  }
  function fieldSection(title, text, isList = false, ordered = false) {
    const section = element('section'); section.append(element('h3', title));
    if (isList) {
      const list = element(ordered ? 'ol' : 'ul'); list.append(...text.map(value => element('li', value))); section.append(list);
    } else section.append(element('p', text));
    return section;
  }
  function resultLabel(card, item, title, control, key) {
    control.id = `${key}-${item.id}`; const label = element('label', title); label.htmlFor = control.id; label.append(control); card.append(label); return label;
  }
  function populateBody(card, item) {
    card.dataset.populated = 'true';
    const body = element('div', undefined, 'test-body');
    const info = element('div', undefined, 'test-info');
    const first = element('section'); first.append(fieldSection('לפני שמתחילים', item.preconditions), fieldSection('צעדי הבדיקה', item.steps, true, true));
    const second = element('section'); second.append(fieldSection('תוצאה צפויה', item.expected));
    if (item.variants.length) second.append(fieldSection('בדיקות גבול ותרחישים נוספים', item.variants, true));
    if (item.note) second.append(element('p', item.note, 'condition-note'));
    info.append(first, second); body.append(info);
    const fields = element('div', undefined, 'result-fields');
    const result = state.results.get(item.id);
    const status = element('select'); status.dataset.resultStatus = ''; addOptions(status, Object.entries(STATUSES)); status.value = result.status;
    resultLabel(fields, item, 'תוצאת הבדיקה', status, 'status');
    const issue = element('input'); issue.type = 'text'; issue.maxLength = 160; issue.dataset.resultIssue = ''; issue.value = result.issueId; issue.placeholder = 'מזהה פנייה או תקלה, אם יש';
    resultLabel(fields, item, 'מזהה פנייה / תקלה', issue, 'issue');
    const notes = element('textarea'); notes.maxLength = 8000; notes.rows = 3; notes.dataset.resultNotes = ''; notes.value = result.notes; notes.placeholder = 'מה נבדק, מה קרה בפועל ומידע לשחזור התקלה';
    resultLabel(fields, item, 'הערות ותוצאה בפועל', notes, 'notes').className = 'notes-field';
    body.append(fields);
    const updated = element('p', updatedText(result.updatedAt), 'test-updated'); body.append(updated);
    status.addEventListener('change', () => {
      result.status = status.value; result.updatedAt = new Date().toISOString(); updated.textContent = updatedText(result.updatedAt);
      updateBadge(item.id); renderCounts(); applyFilters(); scheduleSave();
    });
    for (const [control, key] of [[issue, 'issueId'], [notes, 'notes']]) control.addEventListener('input', () => {
      result[key] = control.value; result.updatedAt = new Date().toISOString(); updated.textContent = updatedText(result.updatedAt); scheduleSave();
    });
    const refs = element('details', undefined, 'sources'); refs.append(element('summary', 'מקורות בקוד וכיסוי בדיקות קיים'));
    refs.append(element('p', 'הפניות לקבצי בדיקה מציינות כיסוי קיים בלבד; הבדיקות לא הורצו מתוך הדף.'));
    const sourceList = element('ul', undefined, 'source-list'); sourceList.append(...(item.sources || []).map(value => element('li', value))); refs.append(sourceList);
    const tests = item.automatedEvidence || [];
    refs.append(element('p', tests.length ? 'קבצי בדיקות קיימים:' : 'לא נמצא קובץ בדיקה ייעודי במיפוי.'));
    if (tests.length) { const testList = element('ul', undefined, 'source-list'); testList.append(...tests.map(value => element('li', value))); refs.append(testList); }
    body.append(refs); card.append(body);
  }
  function updatedText(value) { return value ? `עדכון אחרון: ${new Date(value).toLocaleString('he-IL')}` : 'טרם נרשמה תוצאה לבדיקה זו.'; }
  function updateBadge(id) {
    const result = state.results.get(id); const { badge } = state.cards.get(id);
    badge.textContent = STATUSES[result.status]; badge.className = `status-label status-${result.status}`;
  }
  function renderCounts() {
    const counts = Object.fromEntries(Object.keys(STATUSES).map(key => [key, 0]));
    for (const result of state.results.values()) counts[result.status]++;
    const total = state.catalog.items.length; const done = total - counts['not-run'];
    $('progress').max = total; $('progress').value = done;
    $('progress-description').textContent = `${done} מתוך ${total} בדיקות סומנו (${Math.round(done / total * 100)}%)`;
    const chips = Object.entries(STATUSES).map(([key, label]) => {
      const chip = element('span', label, `count-chip status-${key}`); chip.dataset.statusCount = key; chip.append(element('strong', String(counts[key]))); return chip;
    });
    $('status-counts').replaceChildren(...chips);
  }
  function applyFilters() {
    if (!state.catalog) return;
    const tokens = normalize($('search').value).split(/\s+/).filter(Boolean);
    const category = $('category-filter').value, platform = $('platform-filter').value, role = $('role-filter').value, status = $('status-filter').value, kind = $('kind-filter').value;
    let visible = 0;
    for (const item of state.catalog.items) {
      const match = (!category || item.category === category) && (!platform || item.platforms.includes(platform)) && (!role || item.role === role) && (!status || state.results.get(item.id).status === status) && (!kind || item.kind === kind) && tokens.every(token => item.searchText.includes(token));
      state.cards.get(item.id).card.hidden = !match; if (match) visible++;
    }
    $('visible-count').textContent = `מוצגות ${visible} מתוך ${state.catalog.items.length} בדיקות · ${state.catalog.summary.operations} פעולות ו־${state.catalog.summary.workflows} תרחישים משולבים`;
    $('empty-results').hidden = visible !== 0;
  }
  function replaceResults(validated) {
    state.run = validated.run; state.results = validated.results; displayRun();
    for (const { card } of state.cards.values()) {
      card.open = false; card.querySelector('.test-body')?.remove(); delete card.dataset.populated;
      updateBadge(card.dataset.id);
    }
    renderCounts(); applyFilters(); save();
  }
  async function confirmAction(title, description, actionText) {
    if (typeof $('confirm-dialog').showModal !== 'function') return window.confirm(`${title}\n${description}`);
    $('confirm-title').textContent = title; $('confirm-description').textContent = description; $('confirm-action').textContent = actionText;
    const dialog = $('confirm-dialog');
    return new Promise(resolve => {
      const finish = accepted => { cleanup(); dialog.close(); resolve(accepted); };
      const accept = () => finish(true), cancel = () => finish(false), onCancel = event => { event.preventDefault(); finish(false); };
      const cleanup = () => { $('confirm-action').removeEventListener('click', accept); $('cancel-action').removeEventListener('click', cancel); dialog.removeEventListener('cancel', onCancel); };
      $('confirm-action').addEventListener('click', accept); $('cancel-action').addEventListener('click', cancel); dialog.addEventListener('cancel', onCancel); dialog.showModal(); $('cancel-action').focus();
    });
  }
  function download(body, type, suffix) {
    const url = URL.createObjectURL(new Blob([body], { type }));
    const link = element('a'); link.href = url; link.download = `betshuva-qa-${state.run.date || today()}.${suffix}`; document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 30000);
  }
  function csvCell(value) {
    let text = String(value === undefined ? '' : value);
    if (/^[\s]*[=+@-]/.test(text) || /^[\t\r]/.test(text)) text = `'${text}`;
    return `"${text.replace(/"/g, '""')}"`;
  }
  function exportCsv() {
    const rows = [['מזהה', 'תחום', 'פעולה', 'סוג', 'מכשירים', 'הרשאה', 'תוצאה', 'הערות', 'מזהה פנייה', 'עדכון אחרון', 'גרסה שנבדקה', 'תאריך', 'בודק', 'תנאי קדם', 'צעדים', 'תוצאה צפויה', 'תרחישים נוספים']];
    for (const item of state.catalog.items) {
      const result = state.results.get(item.id);
      rows.push([item.id, item.category, item.title, item.kind === 'workflow' ? 'תרחיש משולב' : 'פעולה', item.platforms.map(p => PLATFORMS[p]).join(' / '), ROLES[item.role], STATUSES[result.status], result.notes, result.issueId, result.updatedAt, state.run.testedVersion, state.run.date, state.run.tester, item.preconditions, item.steps.join('\n'), item.expected, item.variants.join('\n')]);
    }
    download(`\uFEFF${rows.map(row => row.map(csvCell).join(',')).join('\r\n')}`, 'text/csv;charset=utf-8', 'csv');
  }
  async function importFile(file) {
    if (!file) return;
    try {
      // The cap also accommodates a full export with maximum-length Unicode or
      // escaped control characters in every note; per-field bounds still apply.
      if (file.size > 32 * 1024 * 1024) throw new Error('הקובץ גדול מדי. הגודל המרבי הוא 32 MB.');
      const validated = validateImport(JSON.parse(await file.text()));
      if (!await confirmAction('ייבוא תוצאות הבדיקה', 'הייבוא יחליף את התוצאות וההערות של הריצה הנוכחית בדפדפן. מומלץ לייצא אותן לפני ההחלפה. להמשיך?', 'ייבוא והחלפה')) return;
      state.storageAvailable = true; $('storage-notice').hidden = true;
      replaceResults(validated); notify('התוצאות יובאו בהצלחה. הבדיקות שלא הופיעו בקובץ מסומנות ״טרם נבדק״.');
    } catch (error) { notify(`הייבוא לא בוצע: ${error instanceof SyntaxError ? 'הקובץ אינו JSON תקין.' : error.message}`, true, true); }
    finally { $('import-file').value = ''; }
  }
  function bindControls() {
    $('search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(applyFilters, 120); });
    for (const id of ['category-filter', 'platform-filter', 'role-filter', 'status-filter', 'kind-filter']) $(id).addEventListener('change', applyFilters);
    $('clear-filters').addEventListener('click', () => { for (const id of ['search', 'category-filter', 'platform-filter', 'role-filter', 'status-filter', 'kind-filter']) $(id).value = ''; applyFilters(); $('search').focus(); });
    for (const [id, key] of [['tested-version', 'testedVersion'], ['run-date', 'date'], ['tester', 'tester']]) $(id).addEventListener('input', () => { if (state.run) { state.run[key] = $(id).value; scheduleSave(); } });
    $('export-json').addEventListener('click', () => download(JSON.stringify(documentForExport(), null, 2), 'application/json;charset=utf-8', 'json'));
    $('export-csv').addEventListener('click', exportCsv);
    $('import-button').addEventListener('click', () => $('import-file').click());
    $('import-file').addEventListener('change', () => importFile($('import-file').files[0]));
    $('reset-run').addEventListener('click', async () => {
      if (!await confirmAction('איפוס ריצת הבדיקה', 'כל התוצאות, ההערות ופרטי הריצה בדפדפן הזה יימחקו. רשימת הפעולות נשארת. מומלץ לייצא עותק לפני האיפוס.', 'איפוס הריצה')) return;
      state.storageAvailable = true; $('storage-notice').hidden = true;
      replaceResults({ run: defaultRun(), results: new Map(state.catalog.items.map(item => [item.id, blankResult(item.id)])) });
      notify('הריצה אופסה. אפשר להתחיל בדיקה חדשה.');
    });
    $('retry-load').addEventListener('click', () => location.reload());
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') save(); });
    window.addEventListener('pagehide', save);
  }
  async function load() {
    try {
      const response = await fetch('assets/qa-tests/catalog.json?v=qa-20261008', { cache: 'no-store', credentials: 'omit' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const catalog = await response.json();
      if (catalog.schemaVersion !== 1 || !Array.isArray(catalog.items) || !catalog.items.length || !catalog.summary) throw new Error('מבנה קטלוג לא תקין');
      state.catalog = catalog; restore(); displayRun(); populateCatalog();
      for (const id of ['export-json', 'export-csv', 'import-button', 'reset-run']) $(id).disabled = false;
    } catch (error) {
      $('load-error-text').textContent = `לא ניתן לטעון את רשימת הבדיקות. בדקו את החיבור ונסו שוב. (${error.message})`;
      $('load-error').hidden = false; $('test-list').setAttribute('aria-busy', 'false'); $('visible-count').textContent = 'טעינת הקטלוג נכשלה'; $('save-status').textContent = 'הקטלוג לא זמין';
    }
  }
  bindControls(); load();
})();
