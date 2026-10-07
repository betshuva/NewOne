'use strict';

const MINIMUM_AGE = 18;

function parseBirthDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const date = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) return null;
  return value;
}

function ageFromBirthDate(value, now = new Date()) {
  const birthDate = parseBirthDate(value instanceof Date && !Number.isNaN(value.getTime())
    // pg represents DATE as local midnight. Converting it to UTC can move
    // the birthday to the previous day and admit an account too early.
    ? `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, '0')}-${String(value.getDate()).padStart(2, '0')}`
    : String(value || ''));
  if (!birthDate) return null;
  const [year, month, day] = birthDate.split('-').map(Number);
  let age = now.getUTCFullYear() - year;
  if (now.getUTCMonth() + 1 < month ||
      (now.getUTCMonth() + 1 === month && now.getUTCDate() < day)) age--;
  return age;
}

function validateRegistrationAge(value, now = new Date()) {
  const birthDate = parseBirthDate(value);
  const age = ageFromBirthDate(birthDate, now);
  if (!birthDate || age == null || age < 0 || age > 120)
    return { error: 'יש להזין תאריך לידה תקין' };
  if (age < MINIMUM_AGE)
    return { error: 'בתשובה מיועדת לבני 18 ומעלה בלבד', code: 'AGE_RESTRICTED' };
  return { birthDate, age, isTeen: false };
}

// Missing dates may authenticate only to finish setup; every service entry
// point must independently check the stored date, including existing tokens.
function accountAgeError(user, { allowMissing = false, now = new Date() } = {}) {
  if (user?.birth_date == null) {
    return allowMissing ? null : { status: 403, code: 'BIRTH_DATE_REQUIRED',
      error: 'כדי להמשיך יש להשלים תאריך לידה. בתשובה מיועדת לבני 18 ומעלה בלבד' };
  }
  const age = ageFromBirthDate(user.birth_date, now);
  return age != null && age >= MINIMUM_AGE && age <= 120 ? null : {
    status: 403, code: 'AGE_RESTRICTED',
    error: 'בתשובה מיועדת לבני 18 ומעלה בלבד. לסיוע או למחיקת חשבון: support@betshuva.com',
  };
}

function requestAgeError(user, req) {
  // Preserve the ability to delete an account/data using an existing session.
  if (req.method === 'DELETE' && ['/api/account', '/api/account/data'].includes(req.path)) return null;
  const allowMissing = (req.method === 'PUT' && req.path === '/api/profile/birth-date') ||
    (req.method === 'POST' && req.path === '/api/link-phone');
  return accountAgeError(user, { allowMissing });
}

module.exports = { MINIMUM_AGE, parseBirthDate, ageFromBirthDate,
  validateRegistrationAge, accountAgeError, requestAgeError };
