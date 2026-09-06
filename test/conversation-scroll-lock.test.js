'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
const serverSource = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
const contentFilterSource = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'content-filter-policy.js'), 'utf8');
const screenshotSource = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'app_screenshot.dart'), 'utf8');
const screenCaptureWebSource = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'screen_capture_web.dart'), 'utf8');

test('download link loads the current release from the version API', () => {
  assert.match(source, /get\(Uri\.parse\('\$kApi\/version'\)\)/);
  assert.match(source, /FutureBuilder<_ReleaseInfo>/);
  assert.match(source, /release\.apkUri/);
  assert.doesNotMatch(source, /const kVersion = '1\.3\.2'/);
});

test('the guide is displayed as Israel throughout the active application', () => {
  assert.doesNotMatch(source, /אביאל/);
  assert.doesNotMatch(serverSource, /אביאל/);
  assert.match(source, /מדבקת עוזר AI/);
  assert.match(serverSource, /SYSTEM_USER_NAME = 'ישראל מדריך בתשובה'/);
  assert.match(serverSource, /SAFE_INFORMATION_USER_NAME = 'מידע בטוח · AI'/);
});

test('conversation refreshes do not pull users away from older messages', () => {
  const guardedScrollMethods = source.match(
    /void _scrollToBottom\(\{bool force = false\}\)[\s\S]*?if \(!shouldScroll\) return;/g,
  ) || [];
  assert.equal(guardedScrollMethods.length, 2);
  assert.match(source, /_scrollCtrl\.position\.pixels <= 80/);
  assert.match(source,
    /maxScrollExtent - _scrollCtrl\.position\.pixels <=\s*80/);
});

test('pending friendship messages are retried after startup and resume races', () => {
  assert.match(source,
    /_loadMessageRequests\(\)[\s\S]*?WidgetsBinding\.instance\.addPostFrameCallback/);
  assert.match(source,
    /Future<void> _refreshConversationState\(\)[\s\S]*?_loadMessageRequests\(\)/);
  assert.match(source,
    /decision = await showDialog<Map<String, dynamic>>[\s\S]*?catch \(_\) \{[\s\S]*?_showingMessageRequest = false/);
});

test('group messages use chronological scrolling without a reversed web edge', () => {
  const groupStart = source.indexOf('class GroupChatScreen');
  const groupSource = source.slice(groupStart);
  assert.match(groupSource,
    /ListView\.builder\([\s\S]*?final messageIndex = i - \(hasFilterNotice \? 1 : 0\)/);
  assert.doesNotMatch(groupSource.slice(0, groupSource.indexOf('final messageIndex')),
    /reverse: true/);
});

test('admin-only groups disable every member send entry point', () => {
  const groupStart = source.indexOf('class _GroupChatScreenState');
  const groupSource = source.slice(groupStart);
  assert.match(groupSource,
    /bool get _canSendToGroup =>[\s\S]*?_isAdmin \|\| widget\.group\['send_permission'\] != 'admin'/);
  assert.match(groupSource,
    /Future<bool> _ensureCanSendToGroup\(\)[\s\S]*?רק מנהלי הקבוצה רשאים לשלוח הודעות/);
  for (const method of [
    '_showAttachMenu',
    '_showGroupExpressions',
    '_uploadGroupImageBatch',
    '_uploadGroupFile',
  ]) {
    assert.match(groupSource,
      new RegExp(`Future<[^>]+> ${method}\\([^]*?_ensureCanSendToGroup\\(\\)`));
  }
  assert.match(groupSource,
    /if \(_myStatus == 'member' && !_canSendToGroup\)[\s\S]*?רק מנהלי הקבוצה רשאים לשלוח הודעות[\s\S]*?else if \(_myStatus == 'member'\)/);
  assert.match(serverSource,
    /member\.send_permission === 'admin' && member\.role !== 'admin'[\s\S]*?רק מנהלי הקבוצה רשאים לשלוח הודעות/);
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
  assert.match(directImage, /width: 220,[\s\S]*?fit: BoxFit\s*\.contain/);

  const groupStart = source.indexOf('class _GroupChatScreenState');
  const groupSource = source.slice(groupStart);
  const groupImageStart = groupSource.indexOf('_PersistentMediaImage(');
  const groupImage = groupSource.slice(groupImageStart, groupImageStart + 1800);
  assert.equal((groupImage.match(/height: 160/g) || []).length, 3);
  assert.match(groupImage, /width: 200,[\s\S]*?fit: BoxFit\s*\.contain/);
});

test('PDF messages show a first-page preview and open inside the app', () => {
  assert.match(source, /class _InAppPdfScreen/);
  assert.match(source, /PdfViewer\.uri\(/);
  assert.match(source, /class _PdfFirstPagePreview/);
  assert.match(source, /PdfPageView\([\s\S]{0,180}pageNumber: 1/);
  assert.match(source, /isPdfFile[\s\S]{0,220}_openPdfInsideApp/);
  assert.match(source, /maxImageBytesCachedOnMemory: 32 \* 1024 \* 1024/);
});

test('desktop web documents open in the left detail pane', () => {
  assert.match(source, /Widget\? _desktopDocument/);
  assert.match(source, /onDocumentOpen: _openDesktopDocument/);
  assert.match(source, /_desktopIssueId != null[\s\S]{0,500}_desktopDocument != null[\s\S]{0,100}_desktopDocument!/);
  assert.match(source, /embedded: true,[\s\S]{0,100}onClose:/);
});

test('contact filter status uses the full dynamic comparison table', () => {
  const start = source.indexOf('Future<void> _showContactFilterStatus()');
  const end = source.indexOf('Widget _contactFilterStatusButton()', start);
  const dialogSource = source.slice(start, end);
  assert.match(dialogSource, /width: 760/);
  assert.match(dialogSource, /SingleChildScrollView/);
  assert.match(dialogSource, /_InvitationFilterComparisonTable\(/);
  assert.match(dialogSource, /counterpartKind: 'החבר'/);
  assert.match(dialogSource, /groupName: recipientName/);
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

test('filter tables use two-line headers and distinct read-only statuses', () => {
  const start = source.indexOf('class _InvitationFilterComparisonTable');
  const end = source.indexOf('// ── Chat Screen', start);
  const tableSource = source.slice(start, end);
  assert.match(tableSource, /filterHeader\('מה מותר לשלוח', counterpartTarget\)/);
  assert.match(tableSource, /'איזה תוכן אני מוכן לקבל', personalTarget/);
  assert.match(tableSource, /: 'ל - \$namedCounterpart'/);
  assert.match(tableSource, /: 'מ - \$namedCounterpart'/);
  assert.doesNotMatch(tableSource, /: 'ל - קבוצה \$namedCounterpart'/);
  assert.doesNotMatch(tableSource, /: 'מ - קבוצה \$namedCounterpart'/);
  assert.match(tableSource, /'ל - \$namedCounterpart'/);
  assert.match(tableSource, /'מ - \$namedCounterpart'/);
  assert.match(tableSource, /if \(!editable\)/);
  assert.match(tableSource, /Icons\.check_circle : Icons\.block/);
  assert.match(tableSource, /onTap: onTap/);
  assert.match(tableSource, /BoxConstraints\(maxWidth: 680\)/);
  assert.match(
    tableSource,
    /EdgeInsets\.symmetric\(horizontal: 6, vertical: 7\)/,
  );
  assert.doesNotMatch(tableSource, /[„”]/);
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
  assert.match(approvalSource, /groupName: senderName\.toString\(\)/);
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
  assert.match(guardSource, /groupName: recipientName/);
  assert.match(guardSource, /contacts\/\$\{widget\.recipient\['id'\]\}\/filter-settings/);
  assert.match(guardSource, /Text\('שמור והמשך'\)/);
  assert.match(guardSource, /payload\['privateEntry'\]/);
  assert.match(guardSource, /_messages\.add\(normalized\)/);
  assert.match(source, /class _PrivateContactFilterEntry/);
  assert.match(source, /רק אני רואה את ההגדרה הזו/);
  assert.match(source, /אני מוכן לקבל מ\$recipientName/);
  assert.match(source, /recipientAvatarUrl:/);
  assert.match(source, /UserAvatar\(/);
  assert.match(source, /safe-information-ai\.png/);
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
  assert.match(source, /מעלה ואחר כך סורק את \$typeLabel/);
  assert.match(source, /קודם העלאה לאחסון, אחריה בדיקת בטיחות וסינון/);
  assert.match(source, /העלאת הווידאו נכשלה/);
});

test('failed upload attempts are not persisted as chat messages', () => {
  const privateResultStart = source.indexOf('Future<bool> _applyPrivateUploadResult');
  const privateResultEnd = source.indexOf('case _FileUploadOutcome.rejected:', privateResultStart);
  const groupResultStart = source.indexOf('Future<void> _applyGroupUploadResult');
  const groupResultEnd = source.indexOf('case _FileUploadOutcome.rejected:', groupResultStart);
  assert.doesNotMatch(source.slice(privateResultStart, privateResultEnd), /_messages\.add/);
  assert.doesNotMatch(source.slice(groupResultStart, groupResultEnd), /_messages\.add/);
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

test('private and group voice recording display a two-minute countdown', () => {
  const countdowns = source.match(/120 - _recordSeconds/g) || [];
  assert.ok(countdowns.length >= 4);
  assert.match(source, /נותרו \$\{\(\(120 - _recordSeconds\)/);
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

test('listing links open in the desktop detail pane and keep mobile navigation', () => {
  assert.match(
    source,
    /NotificationListener<_OpenListingNotification>[\s\S]*?_desktopListing = notification\.listing/,
  );
  assert.match(
    source,
    /_desktopListing != null[\s\S]*?ListingDetailScreen\([\s\S]*?embedded: true[\s\S]*?onClose:/,
  );
  assert.match(
    source,
    /notification\.dispatch\(context\);[\s\S]*?if \(notification\.handledInDesktopPane\) return;[\s\S]*?Navigator\.push/,
  );
});

test('new accounts default to text and scenery; new conversations inherit account settings', () => {
  const clientDefault = source.slice(
    source.indexOf('Map<String, bool> _newAccountFilter()'),
    source.indexOf('class _RegistrationFilterSelector'));
  assert.match(clientDefault, /'text': true/);
  assert.match(clientDefault, /'nonHumanImages': true/);
  assert.match(clientDefault, /'video': false/);
  assert.match(clientDefault, /'men': false/);
  assert.match(clientDefault, /'women': false/);
  assert.match(clientDefault, /'children': false/);

  assert.match(source, /readFilter\(request\['my_filter'\]\)/);
  assert.match(source, /final Map<String, bool> _contentFilter =\s*_newAccountFilter\(\)/);
  assert.match(source, /_invitationPersonalFilter = readFilter\(data\['myFilter'\]\)/);
  assert.match(contentFilterSource,
    /const NEW_ACCOUNT_CONTENT_FILTER = Object\.freeze\(\{[\s\S]*?nonHumanImages: true/);
  assert.match(serverSource,
    /pendingRow.rows\[0\].content_filter, req\.body\?\.filter/);
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
  assert.match(source, /msg\['deliverySummary'\]\s+is Map/);
  const summaryStart = source.indexOf('class _GroupDeliverySummary');
  const summaryEnd = source.indexOf('class _DocumentModerationCard', summaryStart);
  const summarySource = source.slice(summaryStart, summaryEnd);
  assert.match(summarySource, /alignment: Alignment\.centerRight/);
  assert.match(summarySource, /BoxConstraints\(maxWidth: 420\)/);
  assert.match(summarySource, /mainAxisSize: MainAxisSize\.min/);
  assert.doesNotMatch(summarySource, /Expanded\(/);
});

test('forwarding reuses approved server files and reapplies destination filters', () => {
  assert.match(source,
    /already approved file is forwarded by reference[\s\S]*?if \(localPath != null \|\| localBytes != null\)/);
  assert.doesNotMatch(source,
    /Could not download forwarded file/);
  assert.match(serverSource,
    /m\.file_url=sf\.public_url[\s\S]*?gm\.status='member'/);
  assert.match(serverSource,
    /RECIPIENT_CONTENT_FILTERED/);
  assert.match(serverSource,
    /GROUP_CONTENT_FILTERED/);
});

test('destination filter rejection remains forwardable while safety rejection stays blocked', () => {
  assert.match(serverSource,
    /destinationFilterRejected: true[\s\S]*?moderation_status='approved'/);
  assert.match(serverSource,
    /moderation_status='approved'[\s\S]*?destinationFilterRejected: true/);
  assert.match(serverSource, /forwardAllowed: true/);
  assert.match(serverSource,
    /moderation_details->>'destinationFilterRejected'='true'[\s\S]*?AS forward_allowed/);
  assert.match(serverSource,
    /scanResult\?\.blocked[\s\S]*?moderation_status='rejected'/);
  assert.match(source,
    /status == 'rejected_scan' && message\['forwardAllowed'\] != true/);
  assert.match(source,
    /הקובץ עבר את בדיקת הבטיחות\. ניתן להעביר אותו/);
});

test('multiple chat items can be forwarded to multiple users and groups', () => {
  const forwarding = source.slice(
    source.indexOf('Future<void> forwardChatMessages'),
    source.indexOf('// Google Web Client ID'),
  );
  assert.match(forwarding, /CheckboxListTile/);
  assert.match(forwarding, /selected\.values\.toList\(\)/);
  assert.match(forwarding, /messages\.length \* targets\.length/);
  assert.match(forwarding, /users\/directory/);
  assert.match(forwarding, /לא נמצאו משתתפים או קבוצות/);
  assert.match(source, /בחר כמה פריטים/);
  assert.match(source, /_selectedMessageKeys/);
  assert.match(source, /_forwardSelectedMessages/);
  assert.match(source, /Icons\.radio_button_unchecked/);
  assert.match(source, /IgnorePointer\([\s\S]*?ignoring:\s*_selectedMessageKeys\.isNotEmpty/);
});

test('desktop chat composers stay compact and keep attachment controls on the right', () => {
  const compactComposers = source.match(/BoxConstraints\(maxWidth: 900\)/g) || [];
  assert.ok(compactComposers.length >= 2);
  const rightAlignedComposers =
    source.match(/alignment: Alignment\.centerRight/g) || [];
  assert.ok(rightAlignedComposers.length >= 2);
  const privateComposer = source.slice(
    source.indexOf("tooltip: 'צירוף קובץ'"),
    source.indexOf("hintText: _recipientAllowsText"),
  );
  assert.match(privateComposer, /Icons\.attach_file/);
  assert.match(privateComposer, /Icons\.verified_user_outlined/);
  assert.ok(
    privateComposer.indexOf('Icons.attach_file') <
      privateComposer.indexOf('Icons.verified_user_outlined'),
  );
});

test('app screenshots can open a directly accessible issue without messaging Israel', () => {
  assert.match(source, /navigatorKey: appScreenshotNavigatorKey/);
  assert.doesNotMatch(source, /const AppScreenshotButton\(\)/);
  assert.match(source, /value: 'screenshot'[\s\S]*?Text\('צילום מסך'\)/);
  const threeDotMenus = source.match(/PopupMenuButton<String>/g) || [];
  const screenshotItems = source.match(/value: 'screenshot'/g) || [];
  assert.ok(screenshotItems.length >= threeDotMenus.length,
    'every three-dot popup menu should expose screenshot capture');
  assert.match(source, /label: 'צילום מסך'/);
  assert.match(screenshotSource, /const _israelId = '00000000-0000-4000-8000-000000000002'/);
  assert.match(screenshotSource, /enum _EditTool \{ crop, blur, mark, text \}/);
  assert.match(screenshotSource, /BackdropFilter/);
  assert.match(screenshotSource, /_ScreenshotStrokePainter/);
  assert.match(screenshotSource, /triggerBytesDownload/);
  assert.match(screenshotSource, /navigator\.push<_ScreenshotResult>\(MaterialPageRoute/);
  assert.match(screenshotSource, /appScreenshotBusy/);
  assert.match(screenshotSource, /openRegisteredAppScreenshotMenu/);
  assert.match(source, /registerAppScreenshotMenu\(this, _showAttachMenu\)/);
  assert.match(source, /_openScreenshotThroughIsrael/);
  assert.match(source, /openScreenshotMenuOnStart: true/);
  assert.doesNotMatch(screenshotSource, /showDialog<void>/);
  assert.doesNotMatch(screenshotSource, /Duration\(milliseconds: 220\)/);
  assert.match(screenshotSource, /captureCurrentAppScreen\(\)/);
  assert.match(screenCaptureWebSource, /getDisplayMedia/);
  assert.match(screenCaptureWebSource, /Duration\(milliseconds: 120\)/);
  assert.match(screenCaptureWebSource, /context\.drawImage\(video, 0, 0\)/);
  assert.match(screenCaptureWebSource, /track\.stop\(\)/);
  assert.match(source, /Navigator\.of\(dialogContext\)\.pop\(\);[\s\S]*?openAppScreenshot/);
  assert.match(source, /Navigator\.of\(sheetContext\)\.pop\(\);[\s\S]*?openAppScreenshot/);
  assert.match(screenshotSource, /destination\.kind == 'group'/);
  assert.match(screenshotSource, /צילום המסך נשלח לישראל/);
  assert.match(screenshotSource, /decoded\['status'\] == 'pending'/);
  assert.match(screenshotSource, /פתיחת קריאה/);
  assert.match(screenshotSource,
    /ישראל ישלח בצ׳אט אישור עם פרטי הפנייה וקישור ישיר למעקב/);
  assert.match(screenshotSource, /דיווח תקלה/);
  assert.match(screenshotSource, /בקשת פיתוח/);
  assert.match(screenshotSource, /israelDescription/);
  assert.match(screenshotSource,
    /ישראל הוא מדריך התמיכה של אפליקציית בתשובה/);
  assert.match(screenshotSource, /שלח למשתמש או לקבוצה/);
  assert.match(screenshotSource, /פנייה לתמיכה/);
  assert.match(screenshotSource, /appScreenshotTargetSender/);
  assert.match(source,
    /appScreenshotTargetSender[\s\S]*_forwardChatMessage[\s\S]*'localBytes': bytes/);
  assert.match(source,
    /class _OpenIssuesNotification[\s\S]*handledInDesktopPane/);
  assert.match(source,
    /_desktopIssueId != null[\s\S]*OpenIssuesScreen\([\s\S]*embedded: true/);
  assert.match(screenshotSource,
    /לחיתוך: גרור פנימה מהצד שברצונך להסיר/);
  assert.doesNotMatch(screenshotSource, /child: Slider\(/);
  assert.match(screenshotSource, /מה ניסיתי לעשות:/);
  assert.match(screenshotSource, /מה קרה בפועל:/);
  assert.match(screenshotSource, /מה ציפיתי שיקרה:/);
  assert.match(screenshotSource, /מה הייתי רוצה שיהיה אפשר לעשות:/);
  assert.match(screenshotSource, /איך הייתי מציע שזה יעבוד:/);
  assert.match(screenshotSource, /controller\.text == activeTemplate/);
  assert.match(screenshotSource, /attachmentUrls/);
  assert.match(screenshotSource, /הוסף קבצים לפנייה/);
  assert.match(screenshotSource, /appScreenshotIssueOpened/);
  assert.match(source, /initialIssueId: issueId/);
});

test('group video messages render inline instead of as download-only files', () => {
  assert.match(
    source,
    /==\s*'video'\)[\s\S]*?NativeWebVideoPlayer\([\s\S]*?'group-video-\$\{msg\['fileUrl'\]\}'[\s\S]*?_absoluteMediaUrl\([\s\S]*?_ChatVideoPlayer\(/,
  );
  assert.match(
    source,
    /'group-video-\$\{msg\['fileUrl'\]\}'[\s\S]*?_ImageClassificationBadges\([\s\S]*?_ImageStatusBadge\(/,
  );
});

test('content and harmful-language warnings use the system warning artwork', () => {
  assert.equal(
    fs.existsSync(path.join(
      __dirname,
      '..',
      'flutter_app',
      'assets',
      'guide',
      'system-content-warning.png',
    )),
    true,
  );
  assert.match(source, /class _SystemContentWarningArtwork/);
  assert.match(source, /SnackBar _contentWarningSnackBar/);
  assert.match(source, /errorCode == 'CHAT_CONTENT_BLOCKED'[\s\S]*?_contentWarningSnackBar\(error\)/);
  assert.match(source, /class _DocumentModerationCard[\s\S]*?if \(blocked\)[\s\S]*?_SystemContentWarningArtwork/);
  assert.match(source, /class _UploadResultCard[\s\S]*?if \(blocked && showBlockedArtwork\)[\s\S]*?_SystemContentWarningArtwork/);
  assert.match(source, /uploadStatus == 'blocked_content'[\s\S]*?_SystemContentWarningArtwork/);
});

test('OpenAI and Gemini both decide modesty while local clothing scores are disabled', () => {
  assert.match(serverSource,
    /status: 'disabled_for_modesty_decisions'/);
  assert.match(serverSource,
    /const localBlockedBy = localExplicitContent \? 'localExplicitContent' : null/);
  assert.match(serverSource,
    /adultScore >= 0\.75 \|\| nudityScore >= 0\.65/);
  assert.doesNotMatch(serverSource,
    /nudityScore >= 0\.65 \|\| revealingScore/);
  assert.doesNotMatch(serverSource,
    /const localBlockedBy = strictModesty\.blocked/);
  assert.match(serverSource,
    /classifyOpenAIModesty\(buffer,/);
  assert.match(serverSource,
    /classifyGeminiModesty\(buffer,/);
  assert.match(serverSource, /await Promise\.all/);
  assert.match(serverSource, /person_confirmed_by_openai/);
  assert.match(serverSource, /enforceableViolation\(modestyVerification\)/);
  assert.match(serverSource,
    /modestyReviewsDisagree && safetyConsensusClean[\s\S]*?blocked: false/);
  assert.match(serverSource,
    /action: 'approved_by_clean_safety_consensus'/);
  assert.match(serverSource,
    /MODERATION_CACHE_VERSION = '2026-09-06-classification-verification-13'/);
});

test('safety-rejected media cannot be served locally or restored from Drive', () => {
  assert.match(serverSource,
    /fileState\?\.moderation_status === 'rejected'[\s\S]*?!destinationFilterRejected/);
  assert.match(serverSource, /הקובץ נחסם ואינו זמין לפתיחה או להורדה/);
  assert.equal((serverSource.match(/AND sf\.content_purged_at IS NULL/g) || []).length >= 2,
    true);
});

test('blocked image preview is uploader-only, expires in two minutes and is purged', () => {
  assert.match(serverSource,
    /app\.get\('\/api\/blocked-media\/:id', auth, messageRateLimit/);
  assert.match(serverSource,
    /WHERE id=\$1 AND user_id=\$2 AND file_type='image'/);
  assert.match(serverSource, /blocked_content_expires_at>now\(\)/);
  assert.match(serverSource, /Cache-Control': 'private, no-store, max-age=0'/);
  assert.match(serverSource,
    /blocked_content_expires_at=CASE WHEN file_type='image'[\s\S]*?interval '2 minutes'/);
  assert.match(serverSource, /async function purgeExpiredBlockedImages\(\)/);
  assert.match(serverSource, /setInterval\(purgeExpiredBlockedImages, 5 \* 1000\)/);
  assert.match(source, /class _BlockedImagePreview extends StatefulWidget/);
  assert.match(source, /Authorization': 'Bearer \$\{widget\.token\}'/);
  assert.match(source, /מוצגת רק לך ותימחק בעוד/);
  assert.match(source, /blockedPreviewUrl: message\['blockedPreviewUrl'\]/);
});

test('recovered uploads replace recent local failure cards', () => {
  assert.match(source, /bool _matchesRecentFailedUpload\(/);
  assert.match(source, /Duration\(minutes: 10\)/);
  assert.match(source,
    /recoveredFailedIndex[\s\S]*?_matchesRecentFailedUpload\(message, fileName, 'failed_'\)/);
  assert.match(source,
    /_matchesRecentFailedUpload\([\s\S]*?'failed_group_file_'\)/);
  assert.ok((source.match(/_messages\[recoveredFailedIndex\] = incoming/g) || []).length >= 2);
  assert.ok((source.match(/הסריקה הושלמה והתמונה נשלחה/g) || []).length >= 2);
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
