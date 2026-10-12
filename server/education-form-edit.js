const { normalizeQuestionSelection, surveyQuestionContent } = require('./education-survey-questions');
const { denyTeenEducation } = require('./education-form-policy');

const SCHEMA = `CREATE TABLE IF NOT EXISTS education_form_revisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  form_id UUID NOT NULL REFERENCES education_forms(id) ON DELETE CASCADE,
  edited_by UUID REFERENCES users(id) ON DELETE SET NULL,
  snapshot JSONB NOT NULL,
  responses JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE education_forms ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();`;

function normalizeFormEdit(body, type) {
  const title = String(body.title || '').trim();
  const description = String(body.description || '').trim();
  if (!title || title.length > 160) throw new Error('יש להזין כותרת עד 160 תווים');
  if (description.length > 5000) throw new Error('התיאור ארוך מדי');
  const raw = body.questions;
  const questions = type === 'survey' && Array.isArray(raw) ? raw : [];
  if (type === 'survey' && (!questions.length || questions.length > 20))
    throw new Error('בסקר נדרשות בין שאלה אחת ל־20 שאלות');
  const clean = questions.map(q => {
    const selection = normalizeQuestionSelection(q);
    const text = String(q.text || '').trim();
    const options = Array.isArray(q.options) ? q.options.map(v => String(v).trim()) : [];
    if (!text || text.length > 300 || options.length < 2 || options.length > 12 ||
        options.some(v => !v || v.length > 150) || new Set(options).size !== options.length)
      throw new Error('כל שאלה צריכה תוכן ושתי אפשרויות שונות לפחות');
    return { text, options, ...selection };
  });
  const fileUrl = type === 'survey' ? null : String(body.fileUrl || '').trim() || null;
  const fileName = type === 'survey' ? null : String(body.fileName || '').trim() || null;
  if (fileName && fileName.length > 255) throw new Error('שם הקובץ ארוך מדי');
  if (type === 'signature' && !fileUrl) throw new Error('חובה לצרף מסמך לחתימה');
  const dueAt = body.dueAt ? new Date(body.dueAt) : null;
  if (dueAt && Number.isNaN(dueAt.getTime())) throw new Error('מועד הסיום אינו תקין');
  return { title, description: description || null, questions: clean,
    file_url: fileUrl, file_name: fileName, anonymous: type === 'survey' && body.anonymous === true,
    due_at: dueAt };
}

function contentChanged(form, next) {
  return ['title', 'description', 'file_url', 'anonymous'].some(k => form[k] !== next[k]) ||
    JSON.stringify(surveyQuestionContent(form.questions)) !== JSON.stringify(surveyQuestionContent(next.questions));
}

function registerEducationFormEditing(app, { auth, getPool, io, sendPush, validateContent, canSend }) {
  app.get('/api/education-forms/:id/revisions/:revisionId', auth, async (req, res) => {
    if (denyTeenEducation(req, res)) return;
    try {
      const pool = await getPool();
      const result = await pool.query(`SELECT revision.snapshot,revision.responses,revision.created_at,f.group_id,
        (SELECT gm.role FROM group_members gm WHERE gm.group_id=f.group_id AND gm.user_id=$3 AND gm.status='member') AS viewer_role
        FROM education_form_revisions revision JOIN education_forms f ON f.id=revision.form_id
        WHERE f.id=$1 AND revision.id=$2 AND EXISTS(SELECT 1 FROM group_members gm
          WHERE gm.group_id=f.group_id AND gm.user_id=$3 AND (gm.role='admin' OR f.created_by=$3) AND gm.status='member')`,
      [req.params.id, req.params.revisionId, req.user.id]);
      const revision = result.rows[0];
      if (!revision) return res.status(404).json({ error: 'הגרסה לא נמצאה או שאין הרשאה' });
      const anonymous = revision.snapshot.anonymous === true;
      const names = !anonymous && revision.responses.length ? (await pool.query(
        `SELECT u.id,u.name FROM users u WHERE u.id=ANY($1::uuid[]) AND ($2 OR EXISTS(
          SELECT 1 FROM group_members gm WHERE gm.group_id=$3 AND gm.user_id=u.id AND gm.status='member'))`,
        [revision.responses.map(r => r.user_id), revision.viewer_role === 'admin', revision.group_id])).rows : [];
      const responses = revision.responses.map(r => ({
        response_status: r.response_status, answers: r.answers,
        ...(anonymous ? {} : {name: names.find(u => u.id === r.user_id)?.name ||
            (revision.viewer_role === 'admin' ? r.signer_name || '' : ''),
          submitted_at: r.submitted_at}),
      }));
      res.json({form: revision.snapshot, responses, createdAt: revision.created_at});
    } catch (e) { res.status(500).json({ error: 'טעינת הגרסה הקודמת נכשלה' }); }
  });
  app.put('/api/education-forms/:id', auth, async (req, res) => {
    if (denyTeenEducation(req, res)) return;
    let client, committed = false;
    try {
      client = await (await getPool()).connect();
      await client.query('BEGIN');
      const found = await client.query(`SELECT f.*,g.name AS group_name,g.send_permission,
        (SELECT gm.role FROM group_members gm WHERE gm.group_id=f.group_id AND gm.user_id=$2 AND gm.status='member') AS role FROM education_forms f
        JOIN groups g ON g.id=f.group_id WHERE f.id=$1 AND EXISTS(
          SELECT 1 FROM group_members gm WHERE gm.group_id=f.group_id
          AND gm.user_id=$2 AND (gm.role='admin' OR f.created_by=$2) AND gm.status='member') FOR UPDATE OF f`,
      [req.params.id, req.user.id]);
      const form = found.rows[0];
      if (!form) return res.status(403).json({ error: 'רק יוצר הטופס או מנהל קבוצה יכולים לערוך' });
      if (!req.body.expectedUpdatedAt ||
          new Date(req.body.expectedUpdatedAt).getTime() !== new Date(form.updated_at).getTime())
        return res.status(409).json({ error: 'הטופס עודכן בינתיים. פתח מחדש את העריכה' });
      let next;
      try { next = normalizeFormEdit(req.body, form.form_type); }
      catch (e) { return res.status(400).json({ error: e.message }); }
      if (validateContent) {
        await validateContent(req, client, form.group_id, next, { existingFileUrl: form.file_url });
      } else if (next.file_url && next.file_url !== form.file_url) {
        const file = await client.query(`SELECT 1 FROM stored_files WHERE public_url=$1
          AND moderation_status='approved' AND content_purged_at IS NULL
          AND ((context_type='group' AND context_id=$2) OR user_id=$3)`,
        [next.file_url, form.group_id, req.user.id]);
        if (!file.rows.length) return res.status(400).json({ error: 'יש לבחור קובץ מאושר שהועלה לאתר' });
      }
      const changed = contentChanged(form, next);
      const sendAllowed = canSend ? await canSend(client, form.group_id, form) : true;
      await client.query(`INSERT INTO education_form_revisions(form_id,edited_by,snapshot,responses)
        VALUES($1,$2,$3,COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM education_form_responses r
          WHERE r.form_id=$1),'[]'::jsonb))`, [form.id, req.user.id, JSON.stringify(form)]);
      if (changed) {
        await client.query('DELETE FROM education_response_change_requests WHERE form_id=$1', [form.id]);
        await client.query('DELETE FROM education_form_responses WHERE form_id=$1', [form.id]);
      }
      const saved = await client.query(`UPDATE education_forms SET title=$2,description=$3,
        file_url=$4,file_name=$5,questions=$6,anonymous=$7,due_at=$8,updated_at=now()
        WHERE id=$1 RETURNING *`, [form.id, next.title, next.description, next.file_url,
        next.file_name, JSON.stringify(next.questions), next.anonymous, next.due_at]);
      const recipients = changed && sendAllowed ? (await client.query(
        `SELECT recipient.user_id FROM education_form_recipients recipient
         JOIN education_forms f ON f.id=recipient.form_id
         JOIN group_members gm ON gm.group_id=f.group_id AND gm.user_id=recipient.user_id
         WHERE recipient.form_id=$1 AND gm.status='member'`, [form.id])).rows : [];
      await client.query('COMMIT');
      committed = true;
      io.to(`group:${form.group_id}`).emit('education:updated', {
        groupId: form.group_id, formId: form.id, action: 'edited', answersReset: changed,
      });
      for (const row of form.status === 'open' && (!next.due_at || new Date(next.due_at) > new Date()) ? recipients : []) sendPush(row.user_id, form.group_name,
        `הטופס עודכן: ${next.title}`, { type: 'education_form', groupId: form.group_id, formId: form.id });
      res.json({ ...saved.rows[0], answersReset: changed });
    } catch (e) {
      console.error('education form edit:', e.message);
      res.status(e.status || 500).json({ error: e.status ? e.message : 'שמירת השינויים נכשלה', code: e.code });
    } finally {
      if (client) { if (!committed) await client.query('ROLLBACK').catch(() => {}); client.release(); }
    }
  });
}
module.exports = { SCHEMA, normalizeFormEdit, contentChanged, registerEducationFormEditing };
