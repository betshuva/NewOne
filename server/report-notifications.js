'use strict';

const nodemailer = require('nodemailer');
const REPORT_EMAIL = 'betshuva@betshuva.com';

const SCHEMA = `
ALTER TABLE user_reports ADD COLUMN IF NOT EXISTS notification_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE user_reports ADD COLUMN IF NOT EXISTS notified_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE user_reports ADD COLUMN IF NOT EXISTS notification_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE user_reports ADD COLUMN IF NOT EXISTS notification_next_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE user_reports ADD COLUMN IF NOT EXISTS notification_sent_at TIMESTAMPTZ;
ALTER TABLE user_reports ADD COLUMN IF NOT EXISTS notification_error TEXT;
CREATE INDEX IF NOT EXISTS user_reports_notification_idx ON user_reports(notification_next_at)
  WHERE status='pending' AND notified_version < notification_version;
`;

const types = { user: 'משתמש', message: 'הודעה', group: 'קבוצה', listing: 'מודעה' };
const reasons = { spam: 'ספאם או פרסום מטעה', harassment: 'הטרדה או בריונות',
  inappropriate: 'תוכן פוגעני או לא הולם', fraud: 'התחזות, הונאה או תרמית',
  illegal: 'פעילות או תוכן בלתי חוקיים', other: 'סיבה אחרת' };
const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g,
  ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));

function reportEmail(report, { test = false } = {}) {
  const rows = [
    ['סוג הדיווח', types[report.target_type] || 'תוכן'],
    ['סיבה', reasons[report.reason] || 'סיבה אחרת'],
    ['פרטים שנמסרו', String(report.details || 'לא נמסרו פרטים נוספים').slice(0, 1000)],
    ['מזהה הדיווח', report.id], ['מזהה התוכן או המשתמש', report.target_id],
    ['מזהה המדווח', report.reporter_id],
  ];
  const heading = test ? 'בדיקת התראות דיווחים — אין צורך בטיפול' : 'דיווח חדש בבתשובה — נדרש טיפול';
  const note = test ? 'זו הודעת בדיקה עם נתונים מלאכותיים בלבד; לא נוצר דיווח משתמש.'
    : 'יש לבדוק את הדיווח ולטפל בו במערכת הניהול. הודעה זו אינה אישור שהתוכן נבדק או הוסר. אין להעביר הלאה חומר חשוד.';
  const reviewUrl = 'https://betshuva.com/betshuva-app/admin-reports.html';
  return {
    to: REPORT_EMAIL,
    subject: heading,
    messageId: `<report-${report.id}-${report.notification_version}@betshuva.com>`,
    text: `${heading}\n\n${rows.map(([label, value]) => `${label}: ${value}`).join('\n')}\n\n${note}\n${reviewUrl}`,
    html: `<div dir="rtl" style="font-family:Arial,sans-serif"><h2>${heading}</h2>${rows.map(([label, value]) =>
      `<p><strong>${label}:</strong> <span style="white-space:pre-wrap">${escapeHtml(value)}</span></p>`).join('')}<p>${note}</p><p><a href="${reviewUrl}">פתיחת מסך הדיווחים (נדרשת כניסת מנהל)</a></p></div>`,
  };
}

function createReportTransport(env = process.env) {
  return nodemailer.createTransport({ host: 'smtp.gmail.com', port: 587, secure: false,
    auth: { user: env.EMAIL_FROM, pass: env.EMAIL_APP_PASSWORD },
    requireTLS: true, tls: { rejectUnauthorized: true },
    connectionTimeout: 20000, greetingTimeout: 20000, socketTimeout: 60000 });
}

function createReportNotifier({ getPool, sendMail, onError = () => {} }) {
  let running = false;
  return async function notifyReports() {
    if (running) return 0;
    running = true;
    let sent = 0;
    try {
      const db = await getPool();
      for (let i = 0; i < 10; i++) {
        // The database lease also protects against concurrent server processes.
        const result = await db.query(`WITH candidate AS (
          SELECT id FROM user_reports WHERE status='pending'
            AND notified_version < notification_version AND notification_next_at <= now()
          ORDER BY notification_next_at,created_at FOR UPDATE SKIP LOCKED LIMIT 1
        ) UPDATE user_reports r SET notification_next_at=now()+interval '15 minutes',
          notification_attempts=r.notification_attempts+1
          FROM candidate c WHERE r.id=c.id RETURNING r.*`);
        const report = result.rows[0];
        if (!report) break;
        try {
          const delivery = await sendMail(reportEmail(report));
          if (!delivery?.accepted?.some(address => String(address).toLowerCase() === REPORT_EMAIL)) {
            const error = new Error('Report recipient not accepted');
            error.code = 'RECIPIENT_NOT_ACCEPTED';
            throw error;
          }
          await db.query(`UPDATE user_reports SET
            notified_version=GREATEST(notified_version,$2),notification_sent_at=now(),
            notification_error=NULL WHERE id=$1`, [report.id, report.notification_version]);
          sent++;
        } catch (error) {
          const code = /^[A-Z0-9_]{1,50}$/.test(error.code || '') ? error.code : 'DELIVERY_FAILED';
          const delay = Math.min(3600, 60 * 2 ** Math.min(report.notification_attempts - 1, 6));
          await db.query(`UPDATE user_reports SET notification_error=$3,
            notification_next_at=now()+make_interval(secs=>$4)
            WHERE id=$1 AND notification_version=$2`,
          [report.id, report.notification_version, code, delay]);
          onError(code);
        }
      }
      return sent;
    } finally { running = false; }
  };
}

module.exports = { REPORT_EMAIL, SCHEMA, reportEmail, createReportTransport, createReportNotifier };
