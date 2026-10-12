function denyTeenEducation(req, res) {
  if (!req.user.isTeen) return false;
  res.status(403).json({ error: 'קבוצות אינן זמינות בחשבון נוער', code: 'TEEN_GROUPS_DISABLED' });
  return true;
}

function createEducationFormPolicy({ moderateChatText, recordBlockedChat, verifyMessageLinks,
  linkBlockedMessage, getGroupContentFilter, contentAllowedByFilter,
  getStoredImageClassification, validateApprovedFile, clientIp }) {
  async function canSend(pool, groupId, member) {
    if (member.send_permission === 'admin' && member.role !== 'admin') return false;
    const filter = await getGroupContentFilter(pool, groupId);
    return !!filter && contentAllowedByFilter(filter, 'text', null);
  }

  async function validateContent(req, pool, groupId, form, { existingFileUrl = null } = {}) {
    const text = [form.title, form.description, form.file_name,
      ...(form.questions || []).flatMap(question => [question.text, ...question.options])]
      .filter(Boolean).join('\n');
    if (moderateChatText(text).blocked) {
      recordBlockedChat(req.user.id, 'education_form', text, groupId, clientIp(req));
      throw Object.assign(new Error('הטופס כולל תוכן פוגעני או אסור'),
        { status: 422, code: 'CHAT_CONTENT_BLOCKED' });
    }
    try { await verifyMessageLinks(text); }
    catch { throw Object.assign(new Error(linkBlockedMessage), { status: 422, code: 'UNSAFE_LINK' }); }
    const filter = await getGroupContentFilter(pool, groupId);
    if (!filter || !contentAllowedByFilter(filter, 'text', null))
      throw Object.assign(new Error('סוג התוכן חסום בהגדרות הסינון של הקבוצה'),
        { status: 403, code: 'GROUP_CONTENT_FILTERED' });
    if (form.file_url) {
      const stored = await pool.query(`SELECT file_type FROM stored_files
        WHERE public_url=$1 AND moderation_status='approved' AND content_purged_at IS NULL`, [form.file_url]);
      if (!stored.rows.length || (form.file_url !== existingFileUrl &&
          !await validateApprovedFile(pool, req.user.id, form.file_url, 'group', groupId)))
        throw Object.assign(new Error('הקובץ לא עבר סריקה ואישור עבור קבוצה זו'), { status: 403 });
      const classification = await getStoredImageClassification(pool, form.file_url);
      if (!contentAllowedByFilter(filter, stored.rows[0].file_type, classification))
        throw Object.assign(new Error('סוג התוכן חסום בהגדרות הסינון של הקבוצה'),
          { status: 403, code: 'GROUP_CONTENT_FILTERED' });
    }
  }
  return { canSend, validateContent };
}

module.exports = { denyTeenEducation, createEducationFormPolicy };
