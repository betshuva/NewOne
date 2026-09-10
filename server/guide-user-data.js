'use strict';

const { validateDataPlan } = require('./guide-data-plan');
const { guidePhoneSelect, guideCitySelect } = require('./guide-phone-visibility');

const UNAVAILABLE = 'לא נמצאה קבוצה תואמת שבה אתה חבר פעיל. אפשר להציג חברים רק בקבוצה שאתה חבר בה.';
const GROUP_NAME_PROMPT = 'מה שם הקבוצה שאת חבריה תרצה להציג?';
const GROUP_CHOICE_PROMPT = 'יש כמה קבוצות מתאימות.';
const normalize = value => String(value || '').normalize('NFKC')
  .replace(/[\u0591-\u05BD\u05BF-\u05C7]/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
// Names are plain display data, never app commands, links or model instructions.
const displayName = value => String(value || 'ללא שם')
  .replace(/[\r\n\u0000-\u001f\u202a-\u202e\u2066-\u2069]/g, ' ')
  .replace(/betshuva:\/\//gi, 'betshuva: / /').trim();

const cleanGroupName = value => String(value || '').trim()
  .replace(/^["'„“”«»״]+|["'„“”«»״?؟!.]+$/g, '').trim();

function personalDataRequest(question) {
  const q = normalize(question);
  const countOnly = /(?:^|\s)(?:[וב]?כמה|מספר|ספור|תספור)(?:\s|$)/.test(q);
  // Singular group references identify a specific group's members. A mention
  // of plural "groups" in an account summary must never take this branch.
  if (/(?:מי|רשימ[הת]|הצג|תציג|תראה|הראה|כמה|אילו|מספר|ספור).*(?:^|\s)(?:ב|ל|ה)?קבוצ(?:ה|ת)(?=\s|[?؟!.]|$)/.test(q) &&
      /מי|חבר|משתתפ|אנשים|משתמש|מנהל/.test(q)) {
    const match = q.match(/(?:^|\s)(?:ב|ל|ה)?קבוצ(?:ה|ת)(?=\s|[?؟!.]|$)\s*(?:בשם\s*)?(.*?)\s*$/);
    const name = cleanGroupName(match?.[1]);
    return { kind: 'members', name, adminsOnly: /מנהל/.test(q), countOnly };
  }
  const asksOwn = /(?:^|\s)(?:שלי|לי|אני|שאני)(?=\s|[?؟!.]|$)/.test(q);
  const asksData = /מי|רשימ[הת]|הצג|תציג|תראה|הראה|כמה|אילו|איזה|מספר|ספור/.test(q);
  const contacts = asksData && (asksOwn || /החברים השמורים/.test(q)) &&
    /(?:^|\s)(?:ו?ה?חברים|ו?אנשי (?:ה)?קשר)(?=\s|[?؟!.]|$)/.test(q);
  const groups = /(?:קבוצות שלי|הקבוצות שלי|קבוצות אני חבר|קבוצות אני נמצא|קבוצות שאני חבר)/.test(q) ||
    (asksData && asksOwn && /קבוצות/.test(q));
  if (contacts && groups) return { kind: 'overview', countOnly };
  if (contacts) return { kind: 'contacts', countOnly };
  if (groups) return { kind: 'groups', countOnly };
  return null;
}

function followupDataRequest(question, history = []) {
  const turns = history.slice(-8);
  // The caller supplies this user's guide history without the current message.
  const last = turns.pop();
  if (last?.role !== 'assistant' ||
      !(last.content === GROUP_NAME_PROMPT || String(last.content).startsWith(GROUP_CHOICE_PROMPT))) return null;
  const sentAt = new Date(last.createdAt).getTime();
  if (!Number.isFinite(sentAt) || Date.now() - sentAt > 15 * 60 * 1000) return null;
  const previous = turns.at(-1);
  if (previous?.role !== 'user') return null;
  const original = personalDataRequest(previous.content) ||
    followupDataRequest(previous.content, turns.slice(0, -1));
  if (!original) return null;
  const names = String(question || '').split(/\n|\s+\d+[.)]\s+/)
    .map(line => normalize(cleanGroupName(line.replace(/^\s*\d+[.)]\s*/, '')))).filter(Boolean);
  if (!names.length || names.length > 10 || names.some(name => name.length > 120 || /^\d+$/.test(name) ||
      /[?؟]|^(?:עזוב|בטל|לא משנה|תודה|התעלם)|^(?:איך|למה|מה|מי|כמה|האם|אפשר|תציג|הצג|תראה|הראה|שלח|תשלח|פתח|תפתח|תגיד)(?:\s|$)/.test(name))) return null;
  // Recover an account-summary request even if an older server asked for a
  // group name by mistake. The names are not authorization or query inputs.
  if (original.kind !== 'members') return original;
  return { ...original, name: names[0], names };
}

const FIELD_LABELS = { name: 'שם', phone: 'טלפון', city: 'עיר מגורים', role: 'תפקיד', groups: 'קבוצות' };
function dataTable(rows, request, title) {
  const fields = request.fields || ['name'];
  const cell = (row, field) => {
    const value = field === 'phone' ? row.phone || 'לא זמין להצגה'
      : field === 'city' ? row.city || 'לא זמין להצגה'
      : field === 'groups' ? (row.group_names || []).join(', ')
      : field === 'role' ? row.role_label || (row.role === 'admin' ? 'מנהל/ת' : 'חבר/ה') : row.name;
    return displayName(value);
  };
  return { title, columns: fields.map(field => FIELD_LABELS[field]),
    rows: rows.map(row => fields.map(field => cell(row, field))) };
}

function captureExport(rows, request, title) {
  if (typeof request.collectTable !== 'function') return false;
  request.collectTable(dataTable(rows, request, title));
  return true;
}

function formatDataRows(rows, request) {
  const fields = request.fields || ['name'];
  const table = dataTable(rows, request);
  const cells = table.rows.map(row => row.map(value => value.replace(/\|/g, '&#124;')));
  if (request.format === 'table') {
    return [`| ${fields.map(field => FIELD_LABELS[field]).join(' | ')} |`,
      `| ${fields.map(() => '---').join(' | ')} |`,
      ...cells.map(row => `| ${row.join(' | ')} |`)].join('\n');
  }
  return cells.map((row, i) => `${i + 1}. ${fields.map((field, column) =>
    fields.length === 1 ? row[column] : `${FIELD_LABELS[field]}: ${row[column]}`).join(' · ')}`).join('\n');
}

function profileColumns(request) {
  if (request.countOnly) return '';
  return `${request.fields?.includes('phone') ? `,${guidePhoneSelect}` : ''}${request.fields?.includes('city') ? `,${guideCitySelect}` : ''}`;
}

// All fragments are fixed server code. Requester identity comes from auth, and
// a contact owned by someone else never counts as the requester's contact.
function memberContactFilter(request) {
  if (request.contactFilter === 'saved') return `AND EXISTS (
    SELECT 1 FROM user_contacts saved WHERE saved.owner_id=$1 AND saved.contact_id=gm.user_id)`;
  if (request.contactFilter === 'not_saved') return `AND gm.user_id<>$1 AND NOT EXISTS (
    SELECT 1 FROM user_contacts saved WHERE saved.owner_id=$1 AND saved.contact_id=gm.user_id)`;
  return '';
}
const MEMBER_BLOCK_FILTER = `AND NOT EXISTS (SELECT 1 FROM blocked_users blocked
  WHERE (blocked.blocker_id=$1 AND blocked.blocked_id=gm.user_id)
     OR (blocked.blocker_id=gm.user_id AND blocked.blocked_id=$1))`;

async function allGroupMembers(pool, userId, request) {
  const result = await pool.query(`WITH visible_memberships AS (
    SELECT gm.user_id,g.name AS group_name,gm.role
    FROM group_members mine
    JOIN group_members gm ON gm.group_id=mine.group_id AND gm.status='member'
    JOIN groups g ON g.id=mine.group_id
    WHERE mine.user_id=$1 AND mine.status='member'
      ${memberContactFilter(request)}
      ${MEMBER_BLOCK_FILTER}
      ${request.adminsOnly ? "AND gm.role='admin'" : ''}
  ), visible_people AS (
    SELECT user_id, array_agg(DISTINCT group_name ORDER BY group_name) AS group_names,
      string_agg(group_name || ': ' || CASE WHEN role='admin' THEN 'מנהל/ת' ELSE 'חבר/ה' END,
        '; ' ORDER BY group_name) AS role_label
    FROM visible_memberships GROUP BY user_id
  ) SELECT ${request.countOnly ? 'COUNT(*)::int AS count' :
    `u.name,visible_people.group_names,visible_people.role_label${profileColumns(request)}`}
    FROM visible_people JOIN users u ON u.id=visible_people.user_id
    ${request.countOnly ? '' : 'ORDER BY u.name,u.id'}`, [userId]);
  const label = request.adminsOnly ? 'מנהלים בקבוצות שלך' : 'חברים בקבוצות שלך';
  const filterLabel = request.contactFilter === 'not_saved' ? ' שאינם שמורים באנשי הקשר שלך'
    : request.contactFilter === 'saved' ? ' ששמורים באנשי הקשר שלך' : '';
  if (request.countOnly) return `${label}${filterLabel}: ${result.rows[0].count}. כל אדם נספר פעם אחת.`;
  if (captureExport(result.rows, request, `${label}${filterLabel}`))
    return `${label}${filterLabel}: ${result.rows.length}.`;
  if (!result.rows.length) return `לא נמצאו ${label}${filterLabel}.`;
  return `${label}${filterLabel} (${result.rows.length}; כל אדם מופיע פעם אחת):\n${formatDataRows(result.rows, request)}`;
}

async function executeGuideDataPlan(pool, userId, input, { exportTables } = {}) {
  const plan = validateDataPlan(input);
  if (!plan) return 'לא ניתן לבצע את בקשת הנתונים הזו. נסה לנסח אותה שוב.';
  if (plan.action === 'unsupported')
    return 'המידע שביקשת אינו זמין למדריך. אפשר להציג אנשי קשר שמורים וחברים בקבוצות שלך, להשוות ביניהם, ולכלול שמות, תפקידים, טלפונים ועיר מגורים המותרים להצגה. כתובת מדויקת אינה זמינה.';
  if (plan.action === 'clarify') return 'איזה מידע תרצה להציג, ועל איזו קבוצה או רשימה?';
  const answers = [];
  const tables = [];
  let exportFailed = false;
  for (const item of plan.requests) {
    const itemTables = [];
    const answer = await answerUserDataQuestion(pool, userId, '', { request: {
      kind: item.kind, name: normalize(item.group_query), fields: item.fields,
      countOnly: item.format === 'count', format: item.format, adminsOnly: item.admins_only,
      groupScope: item.group_scope || 'named', contactFilter: item.contact_filter || 'all',
      ...(item.format === 'excel' ? { collectTable: table => itemTables.push(table) } : {}),
    } });
    if (item.format === 'excel' && itemTables.length) tables.push(...itemTables);
    else {
      answers.push(answer);
      if (item.format === 'excel') exportFailed = true;
    }
  }
  if (tables.length && !exportFailed) {
    if (typeof exportTables !== 'function') return 'יצירת קובץ Excel אינה זמינה כרגע. נסה שוב בעוד רגע.';
    return exportTables({ title: tables.length === 1 ? tables[0].title : 'הנתונים שלי',
      tables, answer: answers.join('\n\n') });
  }
  return answers.join('\n\n');
}

async function answerUserDataQuestion(pool, userId, question, { history = [], request: suppliedRequest } = {}) {
  const request = suppliedRequest || personalDataRequest(question) || followupDataRequest(question, history);
  if (!request) return null;
  if (!userId) return 'יש להתחבר כדי להציג את הנתונים שלך.';
  try {
    const answers = [];
    if (request.kind === 'contacts' || request.kind === 'overview') {
      const result = await pool.query(`SELECT ${request.countOnly ? 'COUNT(*)::int AS count'
        : `u.name${profileColumns(request)}`} FROM user_contacts c
        JOIN users u ON u.id=c.contact_id
        WHERE c.owner_id=$1 AND NOT EXISTS (SELECT 1 FROM blocked_users b
          WHERE (b.blocker_id=$1 AND b.blocked_id=u.id)
             OR (b.blocker_id=u.id AND b.blocked_id=$1))
        ${request.countOnly ? '' : 'ORDER BY u.name,u.id'}`, [userId]);
      if (captureExport(result.rows, request, 'אנשי הקשר שלי'))
        return `אנשי הקשר השמורים שלך: ${result.rows.length}.`;
      const answer = request.countOnly ? `אנשי קשר שמורים: ${result.rows[0].count}.` : result.rows.length
        ? `אנשי הקשר השמורים שלך (${result.rows.length}):\n${formatDataRows(result.rows, request)}`
        : 'אין כרגע אנשי קשר שמורים להצגה.';
      if (request.kind === 'contacts') return answer;
      answers.push(answer);
    }
    const audience = await pool.query(`SELECT
      (birth_date IS NULL OR birth_date > CURRENT_DATE - INTERVAL '18 years') AS is_teen
      FROM users WHERE id=$1`, [userId]);
    if (audience.rows[0]?.is_teen !== false)
      return [...answers, 'קבוצות אינן זמינות עדיין בחשבון נוער.'].join('\n');
    if (request.kind === 'members' && request.groupScope === 'all')
      return await allGroupMembers(pool, userId, request);
    const countGroups = request.countOnly && request.kind !== 'members';
    const groups = await pool.query(`SELECT ${countGroups ? 'COUNT(*)::int AS count' : 'g.id,g.name'} FROM groups g
      JOIN group_members mine ON mine.group_id=g.id
      WHERE mine.user_id=$1 AND mine.status='member'
      ${countGroups ? '' : 'ORDER BY g.name,g.id'}`, [userId]);
    if (request.kind === 'groups' || request.kind === 'overview') {
      if (captureExport(groups.rows, request, 'הקבוצות שלי'))
        return `קבוצות שאתה חבר בהן: ${groups.rows.length}.`;
      const answer = countGroups ? `קבוצות שאתה חבר בהן: ${groups.rows[0].count}.` : groups.rows.length
        ? `הקבוצות שאתה חבר בהן (${groups.rows.length}):\n${formatDataRows(groups.rows, request)}`
        : 'אינך חבר כרגע בקבוצות.';
      return [...answers, answer].join('\n');
    }
    if (!request.name) return GROUP_NAME_PROMPT;
    for (const name of request.names || [request.name]) {
      const exact = groups.rows.filter(g => normalize(g.name) === name || g.id === name);
      const matches = exact.length ? exact : groups.rows.filter(g => normalize(g.name).includes(name));
      if (!matches.length) { answers.push(UNAVAILABLE); continue; }
      if (matches.length > 1)
        return `${GROUP_CHOICE_PROMPT} כתוב „מי החברים בקבוצה” ואחריו השם המלא או מזהה הקבוצה:\n${matches.map(g => `${displayName(g.name)} — ${g.id}`).join('\n')}`;
      const group = matches[0];
      // Recheck membership in the same statement as the member read: access may
      // have been revoked since the name lookup. Only active members are exposed.
      const members = await pool.query(`SELECT u.name,gm.role${profileColumns(request)} FROM group_members gm
        JOIN users u ON u.id=gm.user_id
        WHERE gm.group_id=$2 AND gm.status='member'
          AND EXISTS (SELECT 1 FROM group_members mine
            WHERE mine.group_id=gm.group_id AND mine.user_id=$1 AND mine.status='member')
          ${memberContactFilter(request)}
          ${request.contactFilter && request.contactFilter !== 'all' ? MEMBER_BLOCK_FILTER : ''}
        ORDER BY (gm.role='admin') DESC,u.name,u.id`, [userId, group.id]);
      if (!members.rows.length) {
        answers.push(request.contactFilter && request.contactFilter !== 'all'
          ? 'לא נמצאו חברי קבוצה מתאימים בקבוצה נגישה לך.' : UNAVAILABLE);
        continue;
      }
      const rows = request.adminsOnly ? members.rows.filter(m => m.role === 'admin') : members.rows;
      const label = request.adminsOnly ? 'מנהלים' : 'חברים';
      if (captureExport(rows.map(row => ({ ...row, group_names: [group.name] })),
        request, `${label} בקבוצה ${displayName(group.name)}`)) {
        answers.push(`בקבוצה „${displayName(group.name)}” יש ${rows.length} ${label}.`);
        continue;
      }
      answers.push(`בקבוצה „${displayName(group.name)}” יש ${rows.length} ${label}.${request.countOnly ? '' :
        '\n' + (request.fields ? formatDataRows(rows.map(row => ({ ...row, group_names: [group.name] })), request) :
          rows.map((m, i) => `${i + 1}. ${displayName(m.name)}${m.role === 'admin' ? ' (מנהל/ת)' : ''}`).join('\n'))}`);
    }
    return answers.join('\n\n');
  } catch (error) {
    console.error('guide user data:', error.code || error.name);
    // Never let a database failure turn into a model-generated member list.
    return 'לא ניתן לטעון כרגע את הנתונים שלך. נסה שוב בעוד רגע.';
  }
}

module.exports = { answerUserDataQuestion, personalDataRequest, followupDataRequest,
  executeGuideDataPlan, formatDataRows };
