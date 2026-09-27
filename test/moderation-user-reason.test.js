const test=require('node:test'),assert=require('node:assert/strict');
const {imageBlockReason,MODESTY_IMAGE_MESSAGE}=require('../server/moderation-user-reason');
const detailed='התמונה נחסמה — OpenAI: לא צנוע — כתף וחזה חשופים. · Gemini: לא צנוע';
test('image modesty reason is concise, unrelated rejection and video reasons are preserved',()=>{
  assert.equal(imageBlockReason(detailed),MODESTY_IMAGE_MESSAGE);
  assert.equal(imageBlockReason(null,'image','dualModesty'),MODESTY_IMAGE_MESSAGE);
  assert.equal(imageBlockReason('חסום לפי הגדרות הנמען'),'חסום לפי הגדרות הנמען');
  assert.equal(imageBlockReason(detailed,'video'),detailed);
  assert.equal(imageBlockReason(null),null);
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
