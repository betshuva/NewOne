'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');
const server = fs.readFileSync(path.join(root, 'server', 'index.js'), 'utf8');
const client = fs.readFileSync(
  path.join(root, 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('every image stores a local-versus-Google classification comparison', () => {
  assert.match(server,
    /const classificationStats = \{[\s\S]*?localPersonDetected[\s\S]*?googleObjectPersonDetected[\s\S]*?googleFaceDetected[\s\S]*?agreement:/);
  assert.match(server, /falseNegativePerson:/);
  assert.match(server, /falsePositivePerson:/);
  assert.match(server, /correctedByExternal:/);
  assert.match(server,
    /const finalCommon = \{[\s\S]*?classificationStats,/);
  assert.match(server,
    /MODERATION_CACHE_VERSION = '2026-09-06-classification-verification-13'/);
});

test('administrators can view classification reliability by time range', () => {
  assert.match(server,
    /app\.get\('\/api\/admin\/classification-stats', adminAuth/);
  assert.match(server,
    /moderation_details->'classificationStats'/);
  assert.match(server, /agreementRate:/);
  assert.match(server, /averageDurationMs:/);
  assert.match(server, /decisionSummary,/);
  assert.match(server, /recentDecisions: decisionRows/);
  assert.match(server, /decisionIntelligence:/);
  assert.match(server, /externalCorrectionRate:/);
  assert.match(server, /knownExternalUsdPer1000:/);
  assert.match(server, /minimumForStrongRecommendation: 100/);
  assert.match(server,
    /app\.put\('\/api\/admin\/classification-stats\/:id\/ground-truth'/);
  assert.match(server, /CREATE TABLE IF NOT EXISTS moderation_ground_truth/);
  assert.match(server, /name: 'local_upload', phase: 'upload'/);
  assert.match(server, /name: 'local_background', phase: 'later'/);
  assert.match(server, /name: 'final_decision'/);
  assert.match(server,
    /app\.post\('\/api\/admin\/classification-stats\/:id\/rescan'/);
  assert.match(client, /Tab\(icon: Icon\(Icons\.analytics_outlined\), text: 'דיוק הסיווג'\)/);
  assert.match(client, /class _AdminClassificationStatsView/);
  assert.match(client, /לוח החלטות סריקת תמונות/);
  assert.match(client, /בדיקות שבוצעו בזמן ההעלאה/);
  assert.match(client, /בדיקות ופעולות שבוצעו מאוחר יותר/);
  assert.match(client, /מידע להשוואה בלבד/);
  assert.match(client, /רק דורשות טיפול/);
  assert.match(client, /סריקה מלאה מחדש/);
  assert.match(client, /מה כדאי לעשות עכשיו/);
  assert.match(client, /האם בדיקות ההמשך נחוצות/);
  assert.match(client, /עלות לפי יומן הקריאות/);
  assert.match(client, /אמת מאומתת/);
  assert.match(client, /P95/);
  assert.match(client, /עלות לפי יומן הקריאות/);
  assert.match(client, /אומדן היסטורי חלקי/);
  assert.match(client, /ללא דיווח שימוש/);
});
