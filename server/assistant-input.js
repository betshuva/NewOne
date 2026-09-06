'use strict';

async function resolveAssistantInput({ text, fileUrl, fileName }, {
  loadApprovedFile, decryptTranscript,
}) {
  if (!fileUrl) {
    if (!String(text || '').trim()) throw Object.assign(new Error('לא נשלח תוכן'), { status: 400 });
    return { question: String(text).slice(0, 2000), file: null };
  }
  const file = await loadApprovedFile(fileUrl);
  if (!file) throw Object.assign(new Error('הקובץ אינו נגיש או שטרם אושר בסריקה'), { status: 403 });
  let question;
  if (file.file_type === 'audio') {
    question = String(decryptTranscript(file.moderation_details) || '').trim();
    if (!question) throw Object.assign(new Error('לא זוהה דיבור ברור בהקלטה. נסה להקליט שוב.'), { status: 422 });
  } else {
    question = String(text || (file.file_type === 'image'
      ? 'התמונה ששלחתי אושרה. הסבר לי ישירות מה נמצא בסריקה.'
      : 'הסבר לי ישירות על הקובץ ששלחתי.'));
  }
  return { question: question.slice(0, 2000), file: {
    url: fileUrl, name: file.original_name || fileName, type: file.file_type,
  } };
}
module.exports = { resolveAssistantInput };
