const { normalizeQuestionSelection } = require('./education-survey-questions');
const { denyTeenEducation } = require('./education-form-policy');

const SCHEMA = `CREATE TABLE IF NOT EXISTS education_survey_drafts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  created_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  questions JSONB NOT NULL DEFAULT '[]'::jsonb,
  anonymous BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS education_survey_drafts_owner_idx
  ON education_survey_drafts(group_id,created_by,updated_at DESC);`;

function normalizeSurveyDraft(body) {
  const title = String(body.title || '').trim();
  const description = String(body.description || '').trim();
  if (!title || title.length > 160) throw new Error('יש להזין כותרת עד 160 תווים');
  if (description.length > 5000) throw new Error('תיאור הסקר ארוך מדי');
  const questions = body.questions === undefined ? [] : body.questions;
  if (!Array.isArray(questions) || questions.length > 20)
    throw new Error('ניתן לשמור עד 20 שאלות');
  const clean = questions.map(question => {
    const selection = normalizeQuestionSelection(question);
    const text = String(question.text || '').trim();
    const raw = question.options === undefined ? [] : question.options;
    if (!Array.isArray(raw) || raw.length > 12)
      throw new Error('ניתן לשמור עד 12 אפשרויות לכל שאלה');
    const options = raw.map(value => String(value ?? '').trim());
    if (text.length > 300 || options.some(value => value.length > 150))
      throw new Error('השאלה או האפשרויות ארוכות מדי');
    return { text, options, ...selection };
  });
  return { title, description: description || null, questions: clean,
    anonymous: body.anonymous === true };
}

function registerEducationSurveyManagement(app, { auth, getPool, io }) {
  app.get('/api/groups/:id/education-survey-drafts', auth, async (req, res) => {
    if (denyTeenEducation(req, res)) return;
    try {
      const pool = await getPool();
      const admin = await pool.query(`SELECT 1 FROM group_members
        WHERE group_id=$1 AND user_id=$2 AND status='member'`,
      [req.params.id, req.user.id]);
      if (!admin.rows.length) return res.status(403).json({ error: 'לא חבר פעיל בקבוצה' });
      const drafts = await pool.query(`SELECT id,group_id,title,description,questions,anonymous,updated_at
        FROM education_survey_drafts WHERE group_id=$1 AND created_by=$2
        ORDER BY updated_at DESC`, [req.params.id, req.user.id]);
      res.json({ drafts: drafts.rows });
    } catch (e) { res.status(500).json({ error: 'טעינת הטיוטות נכשלה' }); }
  });

  app.post('/api/groups/:id/education-survey-drafts', auth, async (req, res) => {
    if (denyTeenEducation(req, res)) return;
    let draft;
    try { draft = normalizeSurveyDraft(req.body); }
    catch (e) { return res.status(400).json({ error: e.message }); }
    try {
      const pool = await getPool();
      const saved = await pool.query(`INSERT INTO education_survey_drafts
        (group_id,created_by,title,description,questions,anonymous)
        SELECT $1,$2,$3,$4,$5,$6 WHERE EXISTS(SELECT 1 FROM group_members gm JOIN groups g ON g.id=gm.group_id
          WHERE gm.group_id=$1 AND gm.user_id=$2 AND gm.status='member' AND (gm.role='admin' OR g.send_permission<>'admin'))
        RETURNING id,group_id,title,description,questions,anonymous,updated_at`,
      [req.params.id, req.user.id, draft.title, draft.description,
        JSON.stringify(draft.questions), draft.anonymous]);
      if (!saved.rows.length) return res.status(403).json({ error: 'אין הרשאה לשלוח תוכן לקבוצה' });
      res.status(201).json(saved.rows[0]);
    } catch (e) { res.status(500).json({ error: 'שמירת הטיוטה נכשלה' }); }
  });

  app.put('/api/education-survey-drafts/:id', auth, async (req, res) => {
    if (denyTeenEducation(req, res)) return;
    let draft;
    try { draft = normalizeSurveyDraft(req.body); }
    catch (e) { return res.status(400).json({ error: e.message }); }
    try {
      const pool = await getPool();
      const saved = await pool.query(`UPDATE education_survey_drafts draft
        SET title=$3,description=$4,questions=$5,anonymous=$6,updated_at=now()
        WHERE draft.id=$1 AND draft.created_by=$2 AND EXISTS(SELECT 1 FROM group_members gm JOIN groups g ON g.id=gm.group_id
          WHERE gm.group_id=draft.group_id AND gm.user_id=$2 AND gm.status='member' AND (gm.role='admin' OR g.send_permission<>'admin'))
        RETURNING id,group_id,title,description,questions,anonymous,updated_at`,
      [req.params.id, req.user.id, draft.title, draft.description,
        JSON.stringify(draft.questions), draft.anonymous]);
      if (!saved.rows.length) return res.status(404).json({ error: 'הטיוטה לא נמצאה או שאין הרשאה' });
      res.json(saved.rows[0]);
    } catch (e) { res.status(500).json({ error: 'שמירת הטיוטה נכשלה' }); }
  });

  app.delete('/api/education-survey-drafts/:id', auth, async (req, res) => {
    if (denyTeenEducation(req, res)) return;
    try {
      const pool = await getPool();
      const removed = await pool.query(`DELETE FROM education_survey_drafts draft
        WHERE draft.id=$1 AND draft.created_by=$2 AND EXISTS(SELECT 1 FROM group_members gm
          WHERE gm.group_id=draft.group_id AND gm.user_id=$2 AND gm.status='member')
        RETURNING id`, [req.params.id, req.user.id]);
      if (!removed.rows.length) return res.status(404).json({ error: 'הטיוטה לא נמצאה או שאין הרשאה' });
      res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: 'מחיקת הטיוטה נכשלה' }); }
  });

  app.delete('/api/education-forms/:id', auth, async (req, res) => {
    if (denyTeenEducation(req, res)) return;
    let client, committed = false;
    try {
      client = await (await getPool()).connect();
      await client.query('BEGIN');
      const found = await client.query(`SELECT f.id,f.group_id,f.form_type FROM education_forms f
        WHERE f.id=$1 AND EXISTS(SELECT 1 FROM group_members gm
          WHERE gm.group_id=f.group_id AND gm.user_id=$2 AND (gm.role='admin' OR f.created_by=$2) AND gm.status='member')
        FOR UPDATE OF f`, [req.params.id, req.user.id]);
      const form = found.rows[0];
      if (!form) return res.status(403).json({ error: 'רק יוצר הסקר או מנהל קבוצה יכולים למחוק' });
      if (form.form_type !== 'survey')
        return res.status(400).json({ error: 'ניתן למחוק סקרים בלבד' });
      // Keep message identifiers and reply references valid, using the existing
      // deletion marker so an old announcement can no longer open another form.
      const announcements = await client.query(`UPDATE messages
        SET deleted_for_everyone=TRUE,body=NULL,file_url=NULL,file_name=NULL,education_form_id=NULL
        WHERE education_form_id=$1 AND group_id=$2 RETURNING id`, [form.id, form.group_id]);
      await client.query('DELETE FROM education_forms WHERE id=$1', [form.id]);
      await client.query('COMMIT');
      committed = true;
      for (const message of announcements.rows)
        io.to(`group:${form.group_id}`).emit('message:deleted', { id: message.id, groupId: form.group_id });
      io.to(`group:${form.group_id}`).emit('education:updated', {
        groupId: form.group_id, formId: form.id, action: 'deleted',
      });
      res.json({ ok: true });
    } catch (e) {
      console.error('education survey delete:', e.message);
      res.status(500).json({ error: 'מחיקת הסקר נכשלה' });
    } finally {
      if (client) {
        if (!committed) await client.query('ROLLBACK').catch(() => {});
        client.release();
      }
    }
  });
}

module.exports = { SCHEMA, normalizeSurveyDraft, registerEducationSurveyManagement };
