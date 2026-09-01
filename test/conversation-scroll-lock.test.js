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
  assert.match(dialogSource, /מה מותר לשלוח ל„\$recipientName”/);
  assert.match(dialogSource, /איזה תוכן אני מוכן לקבל מ„\$recipientName”/);
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
  assert.match(approvalSource, /מה מותר לשלוח ל„\$senderName”/);
  assert.match(approvalSource, /איזה תוכן אני מוכן לקבל מ„\$senderName”/);
  assert.match(approvalSource, /onPersonalFilterChanged:/);
  assert.match(approvalSource, /אשר והוסף כחבר/);
  assert.match(approvalSource, /Text\('דחה'\)/);
  assert.doesNotMatch(approvalSource, /_chooseGroupInvitationFilter\(/);

  const socketStart = source.indexOf("_socket!.on('message:request'");
  const socketEnd = source.indexOf("_socket!.on('chat:message'", socketStart);
  assert.match(source.slice(socketStart, socketEnd), /_loadMessageRequests\(\)/);
});

test('the first outgoing message to a saved contact requires a receiving-filter choice', () => {
  const guardStart = source.indexOf(
    'Future<bool> _ensureFirstMessageFilterChoice()',
  );
  const guardEnd = source.indexOf('void _showMessageOptions', guardStart);
  const guardSource = source.slice(guardStart, guardEnd);
  assert.match(guardSource, /_requiresFirstMessageFilterChoice != true/);
  assert.match(source, /body\['requiresChoice'\] == true/);
  assert.match(guardSource, /_InvitationFilterComparisonTable\(/);
  assert.match(guardSource, /showCounterpartFilter: false/);
  assert.match(guardSource, /איזה תוכן אני מוכן לקבל מ/);
  assert.match(guardSource, /contacts\/\$\{widget\.recipient\['id'\]\}\/filter-settings/);
  assert.match(guardSource, /Text\('שמור והמשך'\)/);
  assert.match(guardSource, /payload\['privateEntry'\]/);
  assert.match(guardSource, /_messages\.add\(normalized\)/);
  assert.match(source, /class _PrivateContactFilterEntry/);
  assert.match(source, /רק אני רואה את ההגדרה הזו/);
  assert.match(source, /אני מוכן לקבל מ„\$recipientName”/);
  assert.match(source, /recipientAvatarUrl:/);
  assert.match(source, /UserAvatar\(/);
  assert.match(source, /guide_here\.png/);
  assert.match(source, /Text\('עדכון הסינון'\)/);
  assert.match(source, /onUpdate: _showContactFilterStatus/);
  assert.match(source, /await _loadMessages\(silent: true\)/);
  assert.match(source, /body\['counterpartFilterAvailable'\] == true/);
  assert.match(source, /showCounterpartFilter: _counterpartFilterAvailable/);
  assert.match(source, /לאחר שהחבר יאשר את הקשר/);
  assert.match(source, /picUrl: widget\.recipient\['profile_pic_url'\]/);
  assert.match(
    source,
    /showCounterpartFilter && groupFilter\?\[key\] == true/,
  );
  assert.match(
    source,
    /!showCounterpartFilter \|\|\s+groupFilter == null/,
  );

  const sendStart = source.indexOf('Future<void> _send({String? stickerId})');
  const sendEnd = source.indexOf('void _showMessageOptions', sendStart);
  const sendSource = source.slice(sendStart, sendEnd);
  assert.match(
    sendSource,
    /if \(!await _ensureFirstMessageFilterChoice\(\)\) return;/,
  );
  assert.ok(
    sendSource.indexOf('await _ensureFirstMessageFilterChoice()') <
      sendSource.indexOf("_messages.add({"),
    'the private filter must be saved before the message is added or sent',
  );
  const messageRequestStart = sendSource.indexOf("Uri.parse('$kApi/messages')");
  const messageRequestEnd = sendSource.indexOf(');', messageRequestStart);
  assert.doesNotMatch(
    sendSource.slice(messageRequestStart, messageRequestEnd),
    /filter|choice/,
    'the private filter choice must not be included in the message request',
  );

  const uploadStart = source.indexOf('Future<void> _uploadAndSend(');
  const uploadEnd = source.indexOf(
    'Future<bool> _applyPrivateUploadResult',
    uploadStart,
  );
  assert.match(
    source.slice(uploadStart, uploadEnd),
    /if \(!await _ensureFirstMessageFilterChoice\(\)\) return;/,
  );
});

test('blocking closes embedded chat without popping the application route', () => {
  const blockStart = source.indexOf('Future<void> _blockUser()');
  const blockEnd = source.indexOf('Future<void> _sharePhoneContact', blockStart);
  const blockSource = source.slice(blockStart, blockEnd);
  assert.match(blockSource, /response\.statusCode != 200/);
  assert.match(blockSource, /widget\.onBlocked\?\.call\(\)/);
  assert.match(
    blockSource,
    /if \(widget\.embedded\) \{\s+widget\.onClose\?\.call\(\)/,
  );
  assert.match(
    blockSource,
    /else if \(Navigator\.of\(context\)\.canPop\(\)\)/,
  );
  assert.match(blockSource, /חסימת המשתמש נכשלה/);
  assert.match(source, /_users\.removeWhere/);
  assert.match(source, /onBlocked:/);
});

test('picked and recorded videos use the same inline upload animation as images', () => {
  const privateUploadStart = source.indexOf('Future<void> _uploadAndSend(');
  const privateUploadEnd = source.indexOf(
    'Future<bool> _applyPrivateUploadResult',
    privateUploadStart,
  );
  const privateUploadSource = source.slice(privateUploadStart, privateUploadEnd);
  assert.match(privateUploadSource, /fileType == 'video'/);
  assert.match(privateUploadSource, /'status': 'uploading'/);
  assert.match(privateUploadSource, /_messages\.add\(/);

  const groupUploadStart = source.indexOf('Future<void> _uploadGroupFile(');
  const groupUploadEnd = source.indexOf(
    'Future<void> _applyGroupUploadResult',
    groupUploadStart,
  );
  const groupUploadSource = source.slice(groupUploadStart, groupUploadEnd);
  assert.match(groupUploadSource, /fileType == 'video'/);
  assert.match(groupUploadSource, /'status': 'uploading'/);

  assert.match(
    source,
    /\(isVisualUpload \|\| fileType == 'audio'\) &&[\s\S]*?uploadStatus == 'uploading'/,
  );
  assert.match(source, /מעלה וסורק את \$typeLabel/);
  assert.match(source, /העלאת הווידאו נכשלה/);
});

test('voice recordings use web opus, reject empty data, and preload duration', () => {
  const privateVoiceStart = source.indexOf(
    'Future<void> _toggleVoiceRecording()',
  );
  const privateVoiceEnd = source.indexOf('Future<void> _send(', privateVoiceStart);
  const privateVoiceSource = source.slice(privateVoiceStart, privateVoiceEnd);
  assert.match(privateVoiceSource, /AudioEncoder\.opus/);
  assert.match(privateVoiceSource, /voice_message\.webm/);
  assert.match(privateVoiceSource, /recordedSeconds < 1/);
  assert.match(privateVoiceSource, /bytes\.length < 256/);
  assert.match(privateVoiceSource, /await _audioRecorder\.isRecording\(\)/);

  const groupVoiceStart = source.indexOf(
    'Future<void> _toggleVoiceRecording()',
    privateVoiceEnd,
  );
  const groupVoiceEnd = source.indexOf(
    'void _scrollToBottom',
    groupVoiceStart,
  );
  const groupVoiceSource = source.slice(groupVoiceStart, groupVoiceEnd);
  assert.match(groupVoiceSource, /AudioEncoder\.opus/);
  assert.match(groupVoiceSource, /bytes\.length < 256/);

  const playerStart = source.indexOf('class _VoiceMessagePlayerState');
  const playerEnd = source.indexOf('class _ChatVideoPlayer', playerStart);
  const playerSource = source.slice(playerStart, playerEnd);
  assert.match(playerSource, /_prepareSource\(\);/);
  assert.match(playerSource, /await _player\.getDuration\(\)/);
  assert.match(playerSource, /טוען הקלטה\.\.\./);
  assert.match(playerSource, /הטעינה נכשלה — לחצו לניסיון חוזר/);
  assert.match(playerSource, /await _player\.resume\(\)/);
  assert.match(playerSource, /initialDurationSeconds/);
  assert.match(source, /audio_duration_seconds/);
});

test('contacts can be shared from app friends without exposing phone or email', () => {
  const pickerStart = source.indexOf('Future<Map<String, String>?> _pickAppFriend');
  const pickerEnd = source.indexOf(
    'Future<Map<String, String>?> _confirmMyContactShare',
    pickerStart,
  );
  const pickerSource = source.slice(pickerStart, pickerEnd);
  assert.match(pickerSource, /Uri\.parse\('\$kApi\/users'\)/);
  assert.match(pickerSource, /Text\('מהחברים שלי'\)/);
  assert.match(pickerSource, /appUserId/);
  assert.match(pickerSource, /profilePicUrl/);
  assert.match(pickerSource, /יישלח שם, תמונה וקישור לצ׳אט בלבד/);

  const cardStart = source.indexOf('class _SharedContactCard');
  const cardEnd = source.indexOf('class _BetshuvaInvitePreview', cardStart);
  const cardSource = source.slice(cardStart, cardEnd);
  assert.match(cardSource, /UserAvatar\(picUrl: profilePicUrl/);
  assert.match(cardSource, /appUserId\.isNotEmpty \? 'פתח צ׳אט'/);
  assert.match(cardSource, /ChatScreen\(/);
  assert.match(source, /_pickSharedContact\(context, widget\.token\)/);
  assert.match(source, /_pickGroupSharedContact\(\s+context, widget\.token/);
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
