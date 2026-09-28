'use strict';
const {checkTypeSql}=require('./audit-check-presentation');
const UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const IMAGE_CHECKS=['safe_search','object_localization','face_detection','person_presence','modesty',
  'modesty_format_repair','local_safety','local_explicit_content','local_classification'];

// Stable file/frame identity keeps different uploads with the same filename separate.
// Missing or malformed legacy metadata never becomes an invented frame number.
function imageKeySql(alias){
  const d=`${alias}.details`,file=`${d}->>'storedFileId'`,index=`${d}->>'frameIndex'`,time=`${d}->>'frameTimestampMs'`;
  const frame=`CASE WHEN ${index} ~ '^(0|[1-8]?[0-9])$' THEN ${index} END`;
  const timestamp=`CASE WHEN ${time} ~ '^(0|[1-9][0-9]{0,11})$' THEN ${time} END`;
  return `(CASE WHEN ${file} ~* '^${UUID}$' AND
    (${checkTypeSql(alias)} IN (${IMAGE_CHECKS.map(type=>`'${type}'`).join(',')})
      OR (${checkTypeSql(alias)} IS NOT NULL AND ${d}->>'scanPreviewId' ~* '^${UUID}$'))
    THEN lower(${file}) || CASE WHEN (${frame}) IS NOT NULL OR (${timestamp}) IS NOT NULL
      THEN ':frame:' || COALESCE((${frame}),'') || ':' || COALESCE((${timestamp}),'') ELSE ':image' END END)`;
}

function imageNameSql(expression){
  // expression is an internal SQL expression, never request text.
  return `(SELECT CASE WHEN image_key ~ '^${UUID}:(image|frame:[0-9]{0,2}:[0-9]{0,12})$' THEN
    COALESCE(NULLIF((SELECT original_name FROM stored_files WHERE id=split_part(image_key,':',1)::uuid),''),
      'קובץ '||left(image_key,8)) ||
    CASE WHEN split_part(image_key,':',2)='frame' THEN
      CASE WHEN split_part(image_key,':',3)<>'' THEN ' · תמונה '||(split_part(image_key,':',3)::integer+1)::text ELSE '' END ||
      CASE WHEN split_part(image_key,':',4)<>'' THEN ' · שנייה '||
        trim(trailing '.' from trim(trailing '0' from (split_part(image_key,':',4)::numeric/1000)::text)) ELSE '' END
      ELSE '' END END FROM (SELECT (${expression})::text AS image_key OFFSET 0) image_identity)`;
}

async function attachScanImageNames(db,rows){
  const ids=[...new Set(rows.map(row=>String(row.id||'')).filter(id=>/^[1-9][0-9]{0,18}$/.test(id)))];
  if(!ids.length)return;
  const result=await db.query(`SELECT id::text,scan_image_key,${imageNameSql('scan_image_key')} AS scan_image_name
    FROM (SELECT e.id,${imageKeySql('e')} AS scan_image_key FROM audit_events e WHERE e.id=ANY($1::bigint[])) images`,[ids]);
  const byId=new Map(result.rows.map(row=>[row.id,row]));
  for(const row of rows){const image=byId.get(String(row.id));
    row.scanImage=image?.scan_image_key?{key:image.scan_image_key,name:image.scan_image_name}:null;
  }
}
module.exports={imageKeySql,imageNameSql,attachScanImageNames};
