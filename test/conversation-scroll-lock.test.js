'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
const serverSource = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');

test('conversation refreshes do not pull users away from older messages', () => {
  const guardedScrollMethods = source.match(
    /void _scrollToBottom\(\{bool force = false\}\)[\s\S]*?if \(!shouldScroll\) return;/g,
  ) || [];
  assert.equal(guardedScrollMethods.length, 2);
  assert.match(source, /_scrollCtrl\.position\.pixels <= 80/);
  assert.match(source,
    /maxScrollExtent - _scrollCtrl\.position\.pixels <=\s*80/);
});

test('group messages use chronological scrolling without a reversed web edge', () => {
  const groupStart = source.indexOf('class GroupChatScreen');
  const groupSource = source.slice(groupStart);
  assert.match(groupSource,
    /ListView\.builder\([\s\S]*?final messageIndex = i - \(hasFilterNotice \? 1 : 0\)/);
  assert.doesNotMatch(groupSource.slice(0, groupSource.indexOf('final messageIndex')),
    /reverse: true/);
});

test('chat images render separately while full-screen browsing stays available', () => {
  assert.equal((source.match(/_ConsecutiveImageGrid\(/g) || []).length, 1);
  assert.doesNotMatch(source, /imageRunStart|imageRunEnd|imageSequence/);
  assert.match(source,
    /ImagePreviewScreen\([\s\S]{0,600}urls: _conversationImageMessages/);
});

test('blocked upload images can be opened in the full-screen zoom viewer', () => {
  const cardStart = source.indexOf('class _UploadResultCard');
  const cardEnd = source.indexOf('String _imageBlockTitle', cardStart);
  const cardSource = source.slice(cardStart, cardEnd);
  assert.match(cardSource,
    /blocked && imageUrl != null[\s\S]*?ImagePreviewScreen\([\s\S]*?url: imageUrl!/);
  assert.match(cardSource, /Icons\.zoom_in/);
});

test('chat image tiles keep a stable height while media loads', () => {
  const directStart = source.indexOf('class _MessageBubble');
  const directEnd = source.indexOf('class _ImageStatusBadge', directStart);
  const directSource = source.slice(directStart, directEnd);
  const directImageStart = directSource.indexOf('_PersistentMediaImage(');
  const directImage = directSource.slice(directImageStart, directImageStart + 900);
  assert.equal((directImage.match(/height: 180/g) || []).length, 3);
  assert.match(directImage, /width: 220,[\s\S]*?fit: BoxFit\.contain/);

  const groupStart = source.indexOf('class _GroupChatScreenState');
  const groupSource = source.slice(groupStart);
  const groupImageStart = groupSource.indexOf('_PersistentMediaImage(');
  const groupImage = groupSource.slice(groupImageStart, groupImageStart + 1800);
  assert.equal((groupImage.match(/height: 160/g) || []).length, 3);
  assert.match(groupImage, /width: 200,[\s\S]*?fit: BoxFit\.contain/);
});

test('PDF messages show a first-page preview and open inside the app', () => {
  assert.match(source, /class _InAppPdfScreen/);
  assert.match(source, /PdfViewer\.uri\(/);
  assert.match(source, /class _PdfFirstPagePreview/);
  assert.match(source, /PdfPageView\([\s\S]{0,180}pageNumber: 1/);
  assert.match(source, /isPdfFile[\s\S]{0,220}_openPdfInsideApp/);
  assert.match(source, /maxImageBytesCachedOnMemory: 32 \* 1024 \* 1024/);
});

test('contact filter status uses the full dynamic comparison table', () => {
  const start = source.indexOf('Future<void> _showContactFilterStatus()');
  const end = source.indexOf('Widget _contactFilterStatusButton()', start);
  const dialogSource = source.slice(start, end);
  assert.match(dialogSource, /width: 760/);
  assert.match(dialogSource, /SingleChildScrollView/);
  assert.match(dialogSource, /_InvitationFilterComparisonTable\(/);
  assert.match(dialogSource, /counterpartKind: 'החבר'/);
  assert.match(dialogSource, /counterpartFilterLabel: 'סינון החבר'/);
  assert.match(dialogSource, /onPersonalFilterChanged:/);
  assert.match(dialogSource, /filter-settings'[\s\S]*?Text\('שמור'\)/);
  assert.match(dialogSource, /await _loadContactFilterComparison\(\)/);
  assert.match(dialogSource, /לא ניתן לטעון כעת את נתוני הסינון/);
});

test('group status dialog edits personal and admin filters in place', () => {
  const start = source.indexOf('Future<void> _showGroupFilterStatus()');
  const end = source.indexOf('Widget _groupFilterStatusButton()', start);
  const dialogSource = source.slice(start, end);
  assert.match(dialogSource, /onPersonalFilterChanged:/);
  assert.match(dialogSource, /onCounterpartFilterChanged: _isAdmin/);
  assert.match(dialogSource, /groups\/\$_groupId\/personal-filter/);
  assert.match(dialogSource, /groups\/\$_groupId\/filter-settings/);
  assert.match(dialogSource, /Text\('שמור'\)/);
});

test('contact comparison loads both filter columns from one endpoint', () => {
  const methodStart = source.indexOf('Future<bool> _loadContactFilterComparison');
  const methodEnd = source.indexOf('Future<void> _loadMessages', methodStart);
  const methodSource = source.slice(methodStart, methodEnd);
  assert.match(methodSource, /filter-comparison/);
  assert.match(methodSource, /recipientFilter/);
  assert.match(methodSource, /personalFilter/);
});

test('friend approval mirrors group approval with an inline editable filter table', () => {
  const start = source.indexOf('Future<void> _showNextMessageRequest()');
  const end = source.indexOf('Future<void> _registerFcmToken()', start);
  const approvalSource = source.slice(start, end);
  assert.match(approvalSource, /בקשת חברות מאת/);
  assert.match(approvalSource, /_InvitationFilterComparisonTable\(/);
  assert.match(approvalSource, /counterpartKind: 'החבר'/);
  assert.match(approvalSource, /personalFilterLabel: 'הסינון שלי עבור \$senderName'/);
  assert.match(approvalSource, /onPersonalFilterChanged:/);
  assert.match(approvalSource, /אשר והוסף כחבר/);
  assert.match(approvalSource, /Text\('דחה'\)/);
  assert.doesNotMatch(approvalSource, /_chooseGroupInvitationFilter\(/);

  const socketStart = source.indexOf("_socket!.on('message:request'");
  const socketEnd = source.indexOf("_socket!.on('chat:message'", socketStart);
  assert.match(source.slice(socketStart, socketEnd), /_loadMessageRequests\(\)/);
});

test('new accounts, friendships and groups default to text and scenery only', () => {
  const clientDefault = source.slice(
    source.indexOf('Map<String, bool> _newAccountFilter()'),
    source.indexOf('class _RegistrationFilterSelector'));
  assert.match(clientDefault, /'text': true/);
  assert.match(clientDefault, /'nonHumanImages': true/);
  assert.match(clientDefault, /'video': false/);
  assert.match(clientDefault, /'men': false/);
  assert.match(clientDefault, /'women': false/);
  assert.match(clientDefault, /'children': false/);

  assert.match(source, /var selectedFilter = _newAccountFilter\(\)/);
  assert.match(source, /final Map<String, bool> _contentFilter =\s*_newAccountFilter\(\)/);
  assert.match(source, /_invitationPersonalFilter = _newAccountFilter\(\)/);
  assert.match(serverSource,
    /const NEW_ACCOUNT_CONTENT_FILTER = Object\.freeze\(\{[\s\S]*?nonHumanImages: true/);
  assert.match(serverSource,
    /req\.body\?\.filter, NEW_ACCOUNT_CONTENT_FILTER/);
});

test('pending group invitations open automatically on entry and realtime arrival', () => {
  const start = source.indexOf('class _ConversationsScreenState');
  const end = source.indexOf('class ChatScreen', start);
  const conversationsSource = source.slice(start, end);
  assert.match(conversationsSource,
    /_groups = \(jsonDecode\(res\.body\) as List\)\.cast\(\);[\s\S]*?_openNextPendingGroupInvitation\(\)/);
  assert.match(conversationsSource,
    /group\['status'\] == 'pending'/);
  assert.match(conversationsSource,
    /GroupChatScreen\([\s\S]*?group: group/);
  assert.match(conversationsSource,
    /_groupInvitedHandler = \(data\) async[\s\S]*?await _loadGroups\(force: true\)/);
});

test('group senders see persisted per-member filter delivery results', () => {
  assert.match(serverSource,
    /ALTER TABLE messages ADD COLUMN IF NOT EXISTS delivery_summary JSONB/);
  assert.match(serverSource,
    /async function buildGroupDeliveryPlan[\s\S]*?deliveredCount[\s\S]*?blockedCount/);
  assert.match(serverSource,
    /UPDATE messages SET delivery_summary=\$1 WHERE id=\$2/);
  assert.match(serverSource, /deliverySummary: deliveryPlan\.summary/);
  assert.match(source, /class _GroupDeliverySummary/);
  assert.match(source, /נשלח בקבוצה: \$deliveredCount קיבלו/);
  assert.match(source, /נחסם בסינון האישי אצל:/);
  assert.match(source, /msg\['deliverySummary'\] is Map/);
});

test('forwarding reuses approved server files and reapplies destination filters', () => {
  assert.match(source,
    /already approved file is forwarded by reference[\s\S]*?if \(localPath != null\)/);
  assert.doesNotMatch(source,
    /Could not download forwarded file/);
  assert.match(serverSource,
    /m\.file_url=sf\.public_url[\s\S]*?gm\.status='member'/);
  assert.match(serverSource,
    /RECIPIENT_CONTENT_FILTERED/);
  assert.match(serverSource,
    /GROUP_CONTENT_FILTERED/);
});

test('exact duplicate uploads reuse only current-version moderation results', () => {
  assert.match(serverSource, /crypto\.createHash\('sha256'\)/);
  assert.match(serverSource, /content_sha256=\$1[\s\S]*?moderationVersion/);
  assert.match(serverSource, /MODERATION_CACHE_VERSION/);
  assert.match(serverSource,
    /scanResult = \{ \.\.\.cachedScan, cacheHit: true, cacheMatch \}/);
  assert.match(serverSource, /delete scanResult\.blockedCategories/);
});

test('visually equivalent uploads can reuse a current scan safely', () => {
  assert.match(serverSource, /createVisualFingerprint\(file\.buffer\)/);
  assert.match(serverSource, /visuallyEquivalent\(visualFingerprint/);
  assert.match(serverSource, /cacheMatch = 'visual'/);
  assert.match(serverSource, /visual_fingerprint JSONB/);
});

test('group history and realtime messages preserve file identity for PDF preview', () => {
  const groupStart = source.indexOf('class _GroupChatScreenState');
  const groupSource = source.slice(groupStart);
  assert.match(groupSource,
    /final isFile = map\['file_url'\] != null \|\| map\['file_name'\] != null;[\s\S]*?'isFile': isFile/);
  assert.match(groupSource,
    /'isFile': fileUrl != null \|\| fileName != null/);
  assert.match(source, /class _PdfFirstPagePreview/);
  assert.match(source, /PdfViewer\.uri/);
});
