'use strict';

function googleRegistrationRequired(_req, res) {
  return res.status(409).json({ code: 'GOOGLE_REGISTRATION_REQUIRED',
    error: 'הרשמה חדשה מתבצעת באמצעות Google בלבד. לחשבון קיים אפשר להיכנס עם פרטי הכניסה הרגילים' });
}

module.exports = { googleRegistrationRequired };
