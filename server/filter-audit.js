'use strict';

const { personalMessageVisible } = require('./conversation-history');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SQL = `
CREATE TABLE IF NOT EXISTS filter_audit_metadata (
  key text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS filter_audit_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  transaction_id bigint NOT NULL DEFAULT txid_current(),
  kind text NOT NULL,
  user_id uuid,
  actor_id uuid,
  scope_type text,
  scope_id uuid,
  message_id uuid,
  file_id uuid,
  details jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS filter_audit_user_id_idx ON filter_audit_events(user_id,id DESC);
CREATE INDEX IF NOT EXISTS filter_audit_message_id_idx ON filter_audit_events(message_id,id DESC) WHERE message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS filter_audit_file_id_idx ON filter_audit_events(file_id,id DESC) WHERE file_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS filter_audit_revision_idx ON filter_audit_events(user_id,scope_type,scope_id,id DESC)
 WHERE kind IN ('filter_changed','filter_baseline');
CREATE INDEX IF NOT EXISTS filter_audit_telemetry_idx ON filter_audit_events(user_id,created_at DESC)
 WHERE kind IN ('client_displayed','client_hidden');

CREATE OR REPLACE FUNCTION betshuva_filter_audit_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Filter audit events are append-only';
END $$;
DROP TRIGGER IF EXISTS filter_audit_append_only ON filter_audit_events;
CREATE TRIGGER filter_audit_append_only BEFORE UPDATE OR DELETE ON filter_audit_events
 FOR EACH ROW EXECUTE FUNCTION betshuva_filter_audit_append_only();

CREATE OR REPLACE FUNCTION betshuva_filter_audit_actor() RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE value text;
BEGIN
  value := current_setting('app.actor_id',true);
  IF value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN value::uuid; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION betshuva_filter_audit_revision_ids(viewer uuid,scope_kind text,target uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT COALESCE(jsonb_agg(id::text ORDER BY id),'[]'::jsonb) FROM (
   SELECT DISTINCT ON (scope_type,scope_id,details->>'level') id,scope_type,scope_id,details
   FROM filter_audit_events WHERE user_id=viewer AND kind IN ('filter_changed','filter_baseline')
    AND (scope_type='general' OR (scope_type=scope_kind AND scope_id=target))
   ORDER BY scope_type,scope_id,details->>'level',id DESC
 ) latest
$$;

CREATE OR REPLACE FUNCTION betshuva_filter_audit_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_filter jsonb; new_filter jsonb; viewer uuid; target uuid; scope_kind text; level_name text;
  event_kind text; recipient record;
BEGIN
  event_kind := CASE WHEN TG_OP='INSERT' THEN 'filter_baseline' ELSE 'filter_changed' END;
  IF TG_TABLE_NAME='users' THEN
    new_filter:=NEW.content_filter; old_filter:=CASE WHEN TG_OP='UPDATE' THEN OLD.content_filter END;
    viewer:=NEW.id; target:=NULL; scope_kind:='general'; level_name:='general';
  ELSIF TG_TABLE_NAME='user_contacts' THEN
    new_filter:=NEW.filter_override; old_filter:=CASE WHEN TG_OP='UPDATE' THEN OLD.filter_override END;
    viewer:=NEW.owner_id; target:=NEW.contact_id; scope_kind:='contact'; level_name:='contact';
  ELSIF TG_TABLE_NAME='group_members' THEN
    new_filter:=NEW.filter_override; old_filter:=CASE WHEN TG_OP='UPDATE' THEN OLD.filter_override END;
    viewer:=NEW.user_id; target:=NEW.group_id; scope_kind:='group'; level_name:='member';
    IF TG_OP='INSERT' THEN
      INSERT INTO filter_audit_events(kind,user_id,actor_id,scope_type,scope_id,details)
      SELECT 'filter_baseline',NEW.user_id,betshuva_filter_audit_actor(),'group',NEW.group_id,
        jsonb_build_object('after',content_filter,'level','group','source','membership_baseline')
      FROM groups WHERE id=NEW.group_id;
    END IF;
  ELSE
    new_filter:=NEW.content_filter; old_filter:=CASE WHEN TG_OP='UPDATE' THEN OLD.content_filter END;
    viewer:=NEW.creator_id; target:=NEW.id; scope_kind:='group'; level_name:='group';
  END IF;
  IF TG_OP='UPDATE' AND old_filter IS NOT DISTINCT FROM new_filter THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME='groups' THEN
    FOR recipient IN SELECT user_id FROM group_members WHERE group_id=NEW.id AND status='member'
      UNION SELECT NEW.creator_id WHERE NEW.creator_id IS NOT NULL
    LOOP
      INSERT INTO filter_audit_events(kind,user_id,actor_id,scope_type,scope_id,details)
       VALUES(event_kind,recipient.user_id,betshuva_filter_audit_actor(),scope_kind,target,
        jsonb_build_object('before',old_filter,'after',new_filter,'level',level_name,'source','database_trigger'));
    END LOOP;
  ELSE
    INSERT INTO filter_audit_events(kind,user_id,actor_id,scope_type,scope_id,details)
     VALUES(event_kind,viewer,betshuva_filter_audit_actor(),scope_kind,target,
      jsonb_build_object('before',old_filter,'after',new_filter,'level',level_name,'source','database_trigger'));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS filter_audit_users ON users;
CREATE TRIGGER filter_audit_users AFTER INSERT OR UPDATE OF content_filter ON users
 FOR EACH ROW EXECUTE FUNCTION betshuva_filter_audit_change();
DROP TRIGGER IF EXISTS filter_audit_contacts ON user_contacts;
CREATE TRIGGER filter_audit_contacts AFTER INSERT OR UPDATE OF filter_override ON user_contacts
 FOR EACH ROW EXECUTE FUNCTION betshuva_filter_audit_change();
DROP TRIGGER IF EXISTS filter_audit_members ON group_members;
CREATE TRIGGER filter_audit_members AFTER INSERT OR UPDATE OF filter_override ON group_members
 FOR EACH ROW EXECUTE FUNCTION betshuva_filter_audit_change();
DROP TRIGGER IF EXISTS filter_audit_groups ON groups;
CREATE TRIGGER filter_audit_groups AFTER INSERT OR UPDATE OF content_filter ON groups
 FOR EACH ROW EXECUTE FUNCTION betshuva_filter_audit_change();

CREATE OR REPLACE FUNCTION betshuva_filter_audit_classification(value jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN value IS NULL THEN NULL ELSE jsonb_strip_nulls(jsonb_build_object(
  'category',value->'category','detectedCategories',value->'detectedCategories',
  'uncertain',value->'uncertain','source',value->'source')) END
$$;

CREATE OR REPLACE FUNCTION betshuva_filter_audit_message() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE asset record; recipient record; effective jsonb; scope_kind text; target uuid; decision text;
  group_policy jsonb; group_policy_revisions jsonb;
BEGIN
  IF NEW.type NOT IN ('image','video') THEN RETURN NEW; END IF;
  IF NEW.group_id IS NOT NULL AND (NEW.delivery_summary IS NULL OR
     (TG_OP='UPDATE' AND OLD.delivery_summary IS NOT DISTINCT FROM NEW.delivery_summary)) THEN RETURN NEW; END IF;
  IF NEW.group_id IS NULL AND TG_OP<>'INSERT' THEN RETURN NEW; END IF;
  -- Synchronize this snapshot with filter-change transactions that lock the viewer.
  -- The snapshot is persistence-time evidence; it never claims a browser rendered.
  PERFORM u.id FROM users u WHERE (NEW.group_id IS NULL AND u.id=NEW.recipient_id)
    OR (NEW.group_id IS NOT NULL AND EXISTS (SELECT 1 FROM group_members gm
      WHERE gm.group_id=NEW.group_id AND gm.user_id=u.id AND gm.status='member' AND gm.user_id<>NEW.sender_id))
    OR (NEW.group_id IS NOT NULL AND EXISTS (SELECT 1 FROM groups g WHERE g.id=NEW.group_id AND g.creator_id=u.id))
    ORDER BY u.id FOR SHARE;
  IF NEW.group_id IS NOT NULL THEN
    -- Acquire user locks before the group lock, matching preference writers.
    SELECT betshuva_effective_filter(creator.content_filter,g.content_filter),
      betshuva_filter_audit_revision_ids(creator.id,'group',g.id)
      INTO group_policy,group_policy_revisions
      FROM groups g JOIN users creator ON creator.id=g.creator_id
      WHERE g.id=NEW.group_id FOR SHARE OF g;
  END IF;
  SELECT id,moderation_status,betshuva_filter_audit_classification(moderation_details->'classification') AS classification
    INTO asset FROM stored_files WHERE public_url=NEW.file_url;
  FOR recipient IN
    SELECT u.id,u.content_filter,c.filter_override,false AS blocked
      FROM users u LEFT JOIN user_contacts c ON c.owner_id=u.id AND c.contact_id=NEW.sender_id
      WHERE NEW.group_id IS NULL AND u.id=NEW.recipient_id
    UNION ALL
    SELECT u.id,u.content_filter,COALESCE(gm.filter_override,CASE WHEN gm.user_id=g.creator_id THEN g.content_filter END),
      EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(NEW.delivery_summary->'blockedFor','[]'::jsonb)) item WHERE item->>'id'=u.id::text)
      FROM group_members gm JOIN users u ON u.id=gm.user_id JOIN groups g ON g.id=gm.group_id
      WHERE gm.group_id=NEW.group_id AND gm.status='member' AND gm.user_id<>NEW.sender_id
      AND (EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(NEW.delivery_summary->'deliveredTo','[]'::jsonb)) item WHERE item->>'id'=u.id::text)
        OR EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(NEW.delivery_summary->'blockedFor','[]'::jsonb)) item WHERE item->>'id'=u.id::text))
  LOOP
    effective:=betshuva_effective_filter(recipient.content_filter,recipient.filter_override);
    scope_kind:=CASE WHEN NEW.group_id IS NULL THEN 'contact' ELSE 'group' END;
    target:=COALESCE(NEW.group_id,NEW.sender_id);
    decision:=CASE WHEN recipient.blocked THEN 'delivery_blocked_persisted' ELSE 'delivery_persisted' END;
    INSERT INTO filter_audit_events(kind,user_id,actor_id,scope_type,scope_id,message_id,file_id,details)
     VALUES(decision,recipient.id,NEW.sender_id,scope_kind,target,NEW.id,asset.id,
      jsonb_build_object('policy',effective,'generalFilter',recipient.content_filter,'scopedFilter',recipient.filter_override,
       'classification',asset.classification,'moderationStatus',asset.moderation_status,
       'groupFilter',(SELECT content_filter FROM groups WHERE id=NEW.group_id),
       'groupPolicy',group_policy,'groupPolicyRevisionIds',group_policy_revisions,
       'revisionIds',betshuva_filter_audit_revision_ids(recipient.id,scope_kind,target),
       'messageCreatedAt',NEW.created_at,'messageType',NEW.type,'snapshotMoment','persistence',
       'source','database_trigger','provesDisplay',false));
  END LOOP;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS filter_audit_messages ON messages;
CREATE TRIGGER filter_audit_messages AFTER INSERT OR UPDATE OF delivery_summary ON messages
 FOR EACH ROW EXECUTE FUNCTION betshuva_filter_audit_message();

CREATE OR REPLACE FUNCTION betshuva_filter_audit_scan() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.file_type NOT IN ('image','video') THEN RETURN NEW; END IF;
 IF TG_OP='UPDATE' AND OLD.moderation_status IS NOT DISTINCT FROM NEW.moderation_status
   AND OLD.moderation_details->'classification' IS NOT DISTINCT FROM NEW.moderation_details->'classification' THEN RETURN NEW; END IF;
 INSERT INTO filter_audit_events(kind,user_id,actor_id,scope_type,scope_id,file_id,details)
 VALUES('image_classified',NEW.user_id,betshuva_filter_audit_actor(),
  CASE WHEN NEW.context_type='chat' THEN 'contact' ELSE NEW.context_type END,NEW.context_id,NEW.id,
  jsonb_build_object('classification',betshuva_filter_audit_classification(NEW.moderation_details->'classification'),
   'moderationStatus',NEW.moderation_status,'blockedBy',NEW.moderation_details->'blockedBy',
   'destinationFilterRejected',NEW.moderation_details->'destinationFilterRejected','source','database_trigger'));
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS filter_audit_scans ON stored_files;
CREATE TRIGGER filter_audit_scans AFTER INSERT OR UPDATE OF moderation_status,moderation_details ON stored_files
 FOR EACH ROW EXECUTE FUNCTION betshuva_filter_audit_scan();

DO $$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM filter_audit_metadata WHERE key='recording_started') THEN
  INSERT INTO filter_audit_metadata(key) VALUES('recording_started');
  INSERT INTO filter_audit_events(kind,user_id,scope_type,scope_id,details)
    SELECT 'filter_baseline',id,'general',NULL,
     jsonb_build_object('after',content_filter,'level','general','source','installation_baseline') FROM users
    UNION ALL SELECT 'filter_baseline',owner_id,'contact',contact_id,
     jsonb_build_object('after',filter_override,'level','contact','source','installation_baseline') FROM user_contacts
    UNION ALL SELECT 'filter_baseline',user_id,'group',group_id,
     jsonb_build_object('after',filter_override,'level','member','source','installation_baseline') FROM group_members
    UNION ALL SELECT 'filter_baseline',gm.user_id,'group',g.id,
     jsonb_build_object('after',g.content_filter,'level','group','source','installation_baseline')
     FROM groups g JOIN group_members gm ON gm.group_id=g.id AND gm.status='member';
 END IF;
END $$;
`;

async function initializeFilterAudit(pool) {
  const db = typeof pool.connect === 'function' ? await pool.connect() : pool;
  try {
    await db.query('BEGIN');
    await db.query(SQL);
    await db.query('COMMIT');
  } catch (error) {
    await db.query('ROLLBACK');
    throw error;
  } finally {
    if (db !== pool) db.release();
  }
}

async function recordFilterEvent(db, event) {
  if (!event || !/^[a-z][a-z0-9_]{0,63}$/.test(event.kind)) throw new TypeError('Invalid filter event kind');
  const details = JSON.stringify(event.details || {});
  if (Buffer.byteLength(details) > 32768) throw new TypeError('Filter event details exceed limit');
  const result = await db.query(`INSERT INTO filter_audit_events
    (kind,user_id,actor_id,scope_type,scope_id,message_id,file_id,details)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8::jsonb) RETURNING *`, [event.kind,
    event.userId || null,event.actorId || null,event.scopeType || null,event.scopeId || null,
    event.messageId || null,event.fileId || null,details]);
  return result.rows[0];
}

// Persist the policy actually used at a rejection branch. This is distinct from
// a later delivery trigger's snapshot and from untrusted browser telemetry.
async function recordFilterDecision(db, decision) {
  if (!['image','video','document'].includes(decision.messageType)) return null;
  let fileId=decision.fileId || null;
  if (!fileId && decision.fileUrl) {
    fileId=(await db.query('SELECT id FROM stored_files WHERE public_url=$1',
      [decision.fileUrl])).rows[0]?.id || null;
  }
  const classification=decision.classification;
  const snapshot=classification ? Object.fromEntries(
    ['category','detectedCategories','uncertain','source'].filter(key=>classification[key]!==undefined)
      .map(key=>[key,classification[key]])) : null;
  return recordFilterEvent(db,{kind:decision.allowed?'decision_allowed':'decision_blocked',
    userId:decision.userId,actorId:decision.actorId,scopeType:decision.scopeType,
    scopeId:decision.scopeId,messageId:decision.messageId,fileId,
    details:{policy:decision.policy || null,classification:snapshot,
      messageType:decision.messageType,source:decision.source,
      reasonCode:decision.reasonCode || 'content_filter',snapshotMoment:'decision'}});
}

function registerFilterAuditRoutes(app, { auth, adminAuth, getPool }) {
  app.get('/api/admin/filter-timeline', adminAuth, async (req, res) => {
    const userId = req.query.userId || null;
    const messageId = req.query.messageId || null;
    const fileId = req.query.fileId || null;
    const before = req.query.before || null;
    if ([userId,messageId,fileId].some(value => value && (typeof value !== 'string' || !UUID.test(value))) ||
        (before && (typeof before !== 'string' || !/^[1-9]\d{0,18}$/.test(before) || BigInt(before) > 9223372036854775807n)))
      return res.status(400).json({ error: 'מזהה או סמן עמוד לא תקין' });
    const limit = Math.max(1, Math.min(200, Number.parseInt(req.query.limit,10) || 50));
    try {
      const pool = await getPool();
      const [result, metadata] = await Promise.all([
        pool.query(`WITH target_messages AS (
          SELECT m.id,m.sender_id,m.recipient_id,m.group_id,sf.id AS file_id
          FROM messages m LEFT JOIN stored_files sf ON sf.public_url=m.file_url
          WHERE ($2::uuid IS NOT NULL AND m.id=$2) OR ($3::uuid IS NOT NULL AND sf.id=$3)
        )
        SELECT e.*,u.name AS user_name,a.name AS actor_name FROM filter_audit_events e
          LEFT JOIN users u ON u.id=e.user_id LEFT JOIN users a ON a.id=e.actor_id
          WHERE ($1::uuid IS NULL OR e.user_id=$1)
            AND (($2::uuid IS NULL AND $3::uuid IS NULL)
              OR (($2::uuid IS NULL OR e.message_id=$2 OR e.file_id IN (SELECT file_id FROM target_messages UNION SELECT file_id FROM filter_audit_events WHERE message_id=$2))
                AND ($3::uuid IS NULL OR e.file_id=$3))
              OR (e.kind IN ('filter_changed','filter_baseline') AND EXISTS (
                SELECT 1 FROM target_messages m WHERE
                  (m.group_id IS NULL AND e.user_id IN (m.sender_id,m.recipient_id)
                    AND (e.scope_type='general' OR (e.scope_type='contact'
                      AND e.scope_id=CASE WHEN e.user_id=m.sender_id THEN m.recipient_id ELSE m.sender_id END)))
                  OR (m.group_id IS NOT NULL AND (e.scope_type='general' OR (e.scope_type='group' AND e.scope_id=m.group_id))
                    AND (e.user_id=m.sender_id OR EXISTS (SELECT 1 FROM group_members gm
                      WHERE gm.group_id=m.group_id AND gm.user_id=e.user_id)))))
              OR (e.kind IN ('filter_changed','filter_baseline') AND EXISTS (
                SELECT 1 FROM filter_audit_events linked WHERE linked.user_id=e.user_id
                  AND (($3::uuid IS NOT NULL AND linked.file_id=$3)
                    OR ($2::uuid IS NOT NULL AND linked.message_id=$2))
                  AND (e.scope_type='general' OR (e.scope_type=linked.scope_type AND e.scope_id=linked.scope_id))))
              OR (e.kind IN ('history_action','history_image_action','history_restored') AND EXISTS (
                SELECT 1 FROM target_messages m WHERE e.message_id=m.id OR e.details->'messageIds' ? m.id::text)))
            AND ($4::bigint IS NULL OR e.id<$4)
          ORDER BY e.id DESC LIMIT $5`,[userId,messageId,fileId,before,limit+1]),
        pool.query("SELECT created_at FROM filter_audit_metadata WHERE key='recording_started'"),
      ]);
      const events=result.rows.slice(0,limit);
      res.set('Cache-Control','no-store');
      return res.json({events,nextCursor:result.rows.length>limit ? String(events.at(-1).id) : null,
        recordingStartedAt:metadata.rows[0]?.created_at || null});
    } catch (error) {
      console.error('[filter-audit] Timeline read failed:',error.message);
      return res.status(500).json({error:'טעינת היסטוריית הסינון נכשלה'});
    }
  });

  app.post('/api/filter-display-events', auth, async (req,res) => {
    const {messageId,event,clientTime,policyRevision}=req.body || {};
    if (typeof messageId!=='string' || !UUID.test(messageId) || !['displayed','hidden'].includes(event) ||
        (clientTime!==undefined && (typeof clientTime!=='string' || clientTime.length>40 || !Number.isFinite(Date.parse(clientTime)))) ||
        (policyRevision!==undefined && (typeof policyRevision!=='string' || policyRevision.length>100)))
      return res.status(400).json({error:'דיווח תצוגה לא תקין'});
    let db;
    try {
      const pool=await getPool();
      db=await pool.connect();
      await db.query('BEGIN');
      // Serializes telemetry only; never locks policy changes or message delivery.
      await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[`filter-display:${req.user.id}`]);
      const visible=await db.query(`SELECT m.id,m.sender_id,m.group_id,sf.id AS file_id,
        betshuva_filter_audit_classification(sf.moderation_details->'classification') AS classification
        FROM messages m LEFT JOIN stored_files sf ON sf.public_url=m.file_url
        WHERE m.id=$2 AND m.type IN ('image','video') AND ${personalMessageVisible('m','$1')}`,
      [req.user.id,messageId]);
      if (!visible.rows.length) {
        await db.query('ROLLBACK');
        return res.status(404).json({error:'התמונה אינה זמינה למשתמש'});
      }
      const message=visible.rows[0];
      const scopeType=message.group_id?'group':'contact';
      const scopeId=message.group_id || message.sender_id;
      const revisions=await db.query(`SELECT betshuva_filter_audit_revision_ids($1,$2,$3) AS ids,
        (SELECT COALESCE(max(id)::text,'0') FROM filter_audit_events
          WHERE user_id=$1 AND kind IN ('history_action','history_image_action','history_restored')
            AND (message_id=$4 OR details->'messageIds' ? $4::text)) AS history_revision`,
        [req.user.id,scopeType,scopeId,messageId]);
      const observationRevision=`${revisions.rows[0].ids.join(',')}:${revisions.rows[0].history_revision}`;
      const kind=`client_${event}`;
      const limits=await db.query(`SELECT count(*)::int AS count,
        COALESCE(bool_or(message_id=$2 AND kind=$3 AND COALESCE(details->>'observationRevision','')=$4),false) AS duplicate
        FROM filter_audit_events WHERE user_id=$1 AND kind IN ('client_displayed','client_hidden')
          AND created_at>clock_timestamp()-interval '1 day'`,[req.user.id,messageId,kind,observationRevision]);
      if (limits.rows[0].duplicate || limits.rows[0].count>=200) {
        await db.query('COMMIT');
        return res.status(202).json({recorded:false,reason:limits.rows[0].duplicate?'duplicate':'daily_limit'});
      }
      const saved=await recordFilterEvent(db,{kind,userId:req.user.id,actorId:req.user.id,scopeType,scopeId,
        messageId,fileId:message.file_id,details:{clientTime:clientTime || null,
          reportedPolicyRevision:policyRevision || null,revisionIds:revisions.rows[0].ids,observationRevision,
          classification:message.classification,source:'client_report',provesDisplay:false}});
      await db.query('COMMIT');
      return res.status(201).json({recorded:true,id:saved.id,createdAt:saved.created_at});
    } catch(error) {
      if(db) await db.query('ROLLBACK').catch(()=>{});
      console.error('[filter-audit] Display report failed:',error.message);
      return res.status(500).json({error:'שמירת דיווח התצוגה נכשלה'});
    } finally { db?.release(); }
  });
}

module.exports={initializeFilterAudit,recordFilterEvent,registerFilterAuditRoutes,recordFilterDecision,FILTER_AUDIT_SQL:SQL};
