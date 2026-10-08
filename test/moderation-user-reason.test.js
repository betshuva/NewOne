const test=require('node:test'),assert=require('node:assert/strict');
const {imageBlockReason,MODESTY_IMAGE_MESSAGE}=require('../server/moderation-user-reason');
const detailed='התמונה נחסמה — OpenAI: לא צנוע — כתף וחזה חשופים. · Gemini: לא צנוע';
test('image modesty reason is concise, unrelated rejection and video reasons are preserved',()=>{
  assert.equal(imageBlockReason(detailed),MODESTY_IMAGE_MESSAGE);
  assert.equal(imageBlockReason(null,'image','dualModesty'),MODESTY_IMAGE_MESSAGE);
  assert.equal(imageBlockReason('חסום לפי הגדרות הנמען'),'חסום לפי הגדרות הנמען');
  assert.equal(imageBlockReason(detailed,'video'),detailed);
  assert.equal(imageBlockReason(null),null);
  assert.equal(imageBlockReason(null,'image','geminiModesty'),MODESTY_IMAGE_MESSAGE);
  assert.equal(imageBlockReason('נמצאה הפרת לבוש בבדיקת ההשלמה','image',
    'modestyUncertaintyReview','visible_modesty_violation'),MODESTY_IMAGE_MESSAGE);
});
test('incomplete modesty checks retain their reason without claiming a proven violation',()=>{
  for(const reasonCode of ['modesty_uncertain','provider_unavailable','provider_error',
    'uncertainty_review_limit','uncertainty_review_disabled','operation_outcome_unknown','budget_exhausted','deadline_exceeded']) {
    const reason='בדיקת הצניעות לא הושלמה; אין הכרעה סופית';
    assert.equal(imageBlockReason(reason,'image',null,reasonCode),reason);
    assert.equal(imageBlockReason(reason,'image','modestyUncertaintyReview',reasonCode),reason);
    assert.equal(imageBlockReason(reason,'image',reasonCode),reason);
    assert.equal(imageBlockReason(null,'image',null,reasonCode),null);
  }
  for(const reason of ['בדיקת הצניעות אינה ודאית',
    'בדיקת הצניעות אינה זמינה כרגע',
    'בדיקות הצניעות אינן מסכימות או שאין ראיה חזותית ברורה',
    'תקלה בשירות בדיקת הצניעות',
    'לא ניתן לקבוע בוודאות שהאזורים הנראים עומדים בכללי הלבוש']) {
    assert.equal(imageBlockReason(reason),reason);
  }
  assert.equal(imageBlockReason(detailed,'image','dualModesty','modesty_uncertain'),detailed);
  assert.equal(imageBlockReason(detailed,'video',null,'provider_error'),detailed);
});
test('terminal image upload outcomes retain their reason even with earlier modesty block metadata',()=>{
  const {stoppedImageResult}=require('../server/modesty-uncertainty-review');
  for(const reasonCode of ['modesty_uncertain','provider_error','uncertainty_review_limit',
    'uncertainty_review_disabled','operation_outcome_unknown']) {
    const result=stoppedImageResult(reasonCode,{blockedBy:'dualModesty',reason:detailed,
      blocked:true,pending:true,classification:{category:'women',uncertain:false}});
    assert.equal(result.blocked,false);
    assert.equal(result.pending,false);
    assert.equal(result.scanStopped,true);
    assert.equal(result.retryable,false);
    assert.equal(imageBlockReason(result.reason,'image',result.blockedBy,result.reasonCode),result.reason);
    assert.doesNotMatch(result.reason,/תתבצע שוב|תתבצע בדיקה נוספת|נחסמה מטעמי צניעות/);
  }
});
test('purged library image retains a concise reason without modifying diagnostic evidence',()=>{
  const fs=require('node:fs'),vm=require('node:vm');
  const src=fs.readFileSync(require.resolve('../server/index'),'utf8');
  const start=src.indexOf('function mediaLibraryItem('),end=src.indexOf('async function loadStoredFileBytes',start);
  const project=vm.runInNewContext(src.slice(start,end)+'; mediaLibraryItem',{imageBlockReason});
  const row={id:'file',file_type:'image',moderation_status:'rejected',content_purged_at:'2026-09-27',
    moderation_details:{reason:detailed,blockedBy:'dualModesty'},reference_count:0};
  const actual=project(row);
  assert.equal(actual.scanReason,MODESTY_IMAGE_MESSAGE);assert.equal(actual.contentPurged,true);
  assert.equal(row.moderation_details.reason,detailed);
});
