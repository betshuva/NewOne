const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const server = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
const app = fs.readFileSync(path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('personal media API scopes listing and deletion to the authenticated owner', () => {
  assert.match(server, /app\.get\('\/api\/media-library', auth/);
  assert.match(server, /sf\.user_id=\$1/);
  assert.match(server, /app\.delete\('\/api\/media-library\/:id', auth/);
  assert.match(server, /WHERE sf\.id=\$1 AND sf\.user_id=\$2 FOR UPDATE OF sf/);
});

test('permanent media deletion is blocked while an active reference exists', () => {
  assert.match(server, /deleted_for_everyone=FALSE/);
  assert.match(server, /referenceCount > 0/);
  assert.match(server, /code: 'MEDIA_IN_USE'/);
  assert.match(server, /profile_pic_url=\$1/);
  assert.match(server, /listing_images WHERE url=\$1/);
  assert.match(server, /shared_gifs WHERE stored_file_id=\$2 AND status='active'/);
});

test('personal media screen exposes filters, downloads and guarded deletion', () => {
  assert.match(app, /class PersonalMediaScreen extends StatefulWidget/);
  assert.match(app, /'image': 'תמונות'/);
  assert.match(app, /'audio': 'הקלטות'/);
  assert.match(app, /_downloadChatFile\(context/);
  assert.match(app, /מחיקה לצמיתות/);
  assert.match(app, /PersonalMediaScreen\(\s*token: widget\.token/);
  assert.match(app, /\.timeout\(const Duration\(seconds: 10\)\)/);
  assert.match(app, /title: const Text\('המדיה שלי'\)[\s\S]*if \(_backupLoading\)/);
  assert.match(app, /'unassigned': 'לא משויך'/);
  assert.match(app, /לאן הקובץ שייך\?/);
  assert.match(app, /width: 72/);
  assert.match(app, /Widget _mediaTable\(\)/);
  assert.match(app, /_excelHeader\('גודל', 'size', sortColumn: 'size'\)/);
  assert.match(app, /_excelHeader\('תאריך העלאה', 'date', sortColumn: 'date'\)/);
  assert.match(app, /labelText: 'שם הקובץ'/);
  assert.match(app, /label: 'מצב סריקה'/);
  assert.match(app, /label: 'מצב גיבוי'/);
  assert.match(app, /_excelHeader\('סיווג', 'classification'\)/);
  assert.match(app, /label: 'סיווג'/);
  assert.match(app, /String _classificationText/);
  assert.match(app, /if \(type == 'image'\)/);
  assert.doesNotMatch(app, /if \(type == 'image' && item\['releasedAt'\] == null\)/);
});

test('approved personal media can be sent to a friend or group by reference', () => {
  const app = fs.readFileSync(path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  const screen = app.slice(app.indexOf('class PersonalMediaScreen'),
    app.indexOf('// ──', app.indexOf('class PersonalMediaScreen') + 40));
  assert.match(screen, /Future<void> _send\(Map<String, dynamic> item\)/);
  assert.match(screen, /_forwardChatMessage\(context, widget\.token, null/);
  assert.match(screen, /'fileUrl': item\['url'\]/);
  assert.match(screen, /'status': moderationStatus/);
  assert.match(screen, /שליחה לחבר או לקבוצה/);
  assert.match(screen, /enabled: item\['moderationStatus'\] == 'approved'/);
  assert.doesNotMatch(screen, /MultipartRequest\('POST'/);
});

test('images support a full fresh scan and a human classification appeal', () => {
  assert.match(server, /CREATE TABLE IF NOT EXISTS media_classification_appeals/);
  assert.match(server, /app\.post\('\/api\/media-library\/:id\/reclassify', auth, messageRateLimit/);
  assert.match(server, /scanResult = await scanImage\(loaded\.bytes,/);
  assert.match(server, /persistFullImageRescan\(pool, loaded, scanResult, req\.user\.id\)/);
  assert.match(server, /moderation_status='rejected',moderation_details=\$1/);
  assert.match(server, /blocked_content_expires_at=now\(\)\+interval '2 minutes'/);
  assert.match(server, /UPDATE messages SET deleted_for_everyone=TRUE/);
  assert.match(server, /UPDATE users SET profile_pic_url=NULL/);
  assert.match(server, /UPDATE groups SET profile_pic_url=NULL/);
  assert.match(server, /DELETE FROM listing_images/);
  assert.match(server, /UPDATE listings SET image_url=NULL/);
  assert.match(server, /UPDATE education_forms SET file_url=NULL/);
  assert.match(server, /UPDATE shared_gifs SET status='hidden'/);
  assert.match(server, /app\.post\('\/api\/media-library\/:id\/classification-appeal', auth, messageRateLimit/);
  assert.match(server, /INSERT INTO media_classification_appeals/);
  assert.match(server, /SYSTEM_USER_ID, body, loaded\.file\.public_url/);
  assert.match(server, /appealStatus: row\.appeal_status/);
  assert.match(server, /type === 'appeals'/);
  assert.match(server, /app\.patch\('\/api\/admin\/classification-appeals\/:id', adminAuth/);
  assert.match(server, /source: 'human_review'/);

  const app = fs.readFileSync(path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(app, /סריקה נוספת/);
  assert.doesNotMatch(app, /בדיקת סיווג נוספת/);
  assert.match(app, /ערעור על הסיווג/);
  assert.match(app, /בקשה לבדיקה אנושית/);
  assert.match(app, /צוות ההדרכה של בתשובה/);
  assert.match(app, /הערעור נשלח לבדיקה\. נעדכן אותך לאחר סיום הבירור/);
  const admin = fs.readFileSync(path.join(__dirname, '..', 'admin.html'), 'utf8');
  assert.match(admin, /ערעורי סיווג/);
  assert.match(admin, /resolveClassificationAppeal/);
});

test('personal media destinations are named without exposing inaccessible contexts', () => {
  assert.match(server, /AS destinations/);
  assert.match(server, /m\.sender_id=\$1 OR m\.recipient_id=\$1 OR EXISTS/);
  assert.match(server, /gm\.user_id=\$1 AND gm\.status='member'/);
  assert.match(server, /l\.user_id=\$1/);
  assert.match(server, /ef\.created_by=\$1/);
  assert.match(server, /allowedScopes/);
  assert.match(server, /const sortSql =/);
  assert.match(server, /sf\.original_name ILIKE/);
  assert.match(server, /sf\.file_size >=/);
  assert.match(server, /sf\.created_at >=/);
  assert.match(server, /allowedModeration/);
  assert.match(server, /allowedBackup/);
  assert.match(server, /allowedClassifications/);
  assert.match(server, /detectedCategories' \? \$13/);
});

test('media table has Excel-style per-column filters', () => {
  const app = fs.readFileSync(path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(app, /Widget _excelHeader/);
  assert.match(app, /Future<void> _showExcelFilter/);
  assert.match(app, /Icons\.filter_alt/);
  assert.match(app, /_excelHeader\('שם הקובץ', 'name'\)/);
  assert.match(app, /_excelHeader\('שייך אל', 'scope'\)/);
  assert.match(app, /_excelHeader\('סיווג', 'classification'\)/);
  assert.match(app, /נקה סינון/);
});

test('media destinations carry safe ids and open their original app location', () => {
  assert.match(server, /'kind',CASE WHEN m\.group_id IS NULL THEN 'chat' ELSE 'group_chat' END/);
  assert.match(server, /'targetId',CASE WHEN m\.group_id IS NULL THEN other_user\.id ELSE m\.group_id END/);
  assert.match(server, /'messageId',m\.id/);
  assert.match(server, /'kind','listing','targetId',l\.id/);
  assert.match(server, /'kind','form','targetId',ef\.id/);
  const app = fs.readFileSync(path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(app, /Future<void> _openDestination/);
  assert.match(app, /ChatScreen\([\s\S]*recipient:/);
  assert.match(app, /GroupChatScreen\(/);
  assert.match(app, /ListingDetailScreen\(/);
  assert.match(app, /EducationFormDetailsScreen\(/);
  assert.match(app, /trailing: const Icon\(Icons\.open_in_new/);
});

test('released cloud media retries transient image failures in place', () => {
  assert.match(app, /class _PersistentMediaImageState/);
  assert.match(app, /void _scheduleRetry\(\)/);
  assert.match(app, /_retryAttempt >= 4/);
  assert.match(app, /Duration\(seconds: 1 << _retryAttempt\)/);
  assert.match(app, /setState\(\(\) => _bytes = _loadPersistentMedia\(widget\.url\)\)/);
});

test('full image rescan is available from private, group and fullscreen message options', () => {
  assert.match(server, /app\.post\('\/api\/media\/reclassify', auth, messageRateLimit/);
  assert.match(server, /loadAccessibleMediaForReview/);
  assert.match(server, /m\.sender_id=\$1 OR m\.recipient_id=\$1/);
  assert.match(server, /gm\.user_id=\$1 AND gm\.status='member'/);
  const app = fs.readFileSync(path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(app, /Future<void> _requestImageReclassification/);
  assert.ok((app.match(/title: const Text\('סריקה נוספת'\)/g) || []).length >= 2);
  assert.match(app, /body\['status'\] == 'rejected'/);
  assert.match(app, /onMessageOptions: onMessageOptions/);
  assert.match(app, /Icons\.more_vert/);
});
