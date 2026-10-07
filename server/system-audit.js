const { attachOperationMedia } = require('./audit-media');
const { attachOperationPreviews } = require('./audit-scan-previews');
const { attachScanImageNames } = require('./audit-image-names');
const { attachStoppedScanEvidence } = require('./audit-stopped-evidence');
'use strict';
const {COST_SQL,COST_FIELDS,enabled:costsEnabled,usageSql,presentUsage}=require('./audit-costs');
const {refreshFx}=require('./audit-fx');

const { AsyncLocalStorage } = require('node:async_hooks');
const { randomUUID } = require('node:crypto');
const { AUDIT_COLUMN_ORDER_SQL } = require('./audit-column-order');
const { ACTION_CATALOG, EVENT_KIND_LABELS, COVERAGE, STATUSES, CATEGORIES, lookupAction, sanitizeAuditDetails } = require('./system-audit-catalog');
const { CHECK_TYPE_LABELS, CHECK_OUTCOME_LABELS, presentAuditCheck, checkTypeSql,
  checkOutcomeSql } = require('./audit-check-presentation');

const {FIELDS:EXTENDED_FIELDS,hasField:hasExtendedField,parentField,stepField,fieldSql:extendedFieldSql,fieldLabelSql,OPERATION_OUTCOME_JOINS}=require('./audit-field-filters');

const {DISPATCH_SQL,DISPATCH_FIELDS,wrapQuery:wrapDispatchQuery,presentDispatch,prepareQuery:prepareDispatchQuery}=require('./audit-dispatch');
const context = new AsyncLocalStorage();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CODE = /^[a-z][a-z0-9_.:-]{0,79}$/;
const EXECUTORS = new Set(['user', 'admin', 'worker', 'system', 'provider', 'client', 'unknown']);
const TERMINAL = ['completed', 'succeeded', 'failed', 'blocked', 'rejected', 'cancelled', 'partial', 'skipped'];
const FALLBACK_STATUSES = ['running', 'pending', 'queued', ...TERMINAL].map(code => ({ code, label: code }));
const SYSTEM_AUDIT_SQL = `
${AUDIT_COLUMN_ORDER_SQL}
CREATE TABLE IF NOT EXISTS audit_metadata (
  key text PRIMARY KEY,
  created_at timestamptz(3) NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS audit_operations (
  id uuid PRIMARY KEY,
  created_at timestamptz(3) NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz(3) NOT NULL DEFAULT clock_timestamp(),
  action text NOT NULL,
  category text NOT NULL,
  initiator_id uuid,
  initiator_name text,
  initiator_short_id text,
  target_type text,
  target_id uuid,
  source text NOT NULL,
  status text NOT NULL,
  status_source text NOT NULL DEFAULT 'operation_started',
  reason_code text,
  root_event_id bigint,
  event_count bigint NOT NULL DEFAULT 0,
  duration_ms bigint NOT NULL DEFAULT 0
);
ALTER TABLE audit_operations ADD COLUMN IF NOT EXISTS status_source text NOT NULL DEFAULT 'operation_started';
ALTER TABLE audit_operations ADD COLUMN IF NOT EXISTS media_type text;
ALTER TABLE audit_operations ADD COLUMN IF NOT EXISTS capture_kind text;
ALTER TABLE audit_operations ADD COLUMN IF NOT EXISTS recipient_type text;
ALTER TABLE audit_operations ADD COLUMN IF NOT EXISTS recipient_id uuid;
ALTER TABLE audit_operations ADD COLUMN IF NOT EXISTS recipient_name text;
ALTER TABLE audit_operations ADD COLUMN IF NOT EXISTS recipient_short_id text;
CREATE TABLE IF NOT EXISTS audit_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation_id uuid NOT NULL REFERENCES audit_operations(id),
  parent_event_id bigint,
  created_at timestamptz(3) NOT NULL DEFAULT clock_timestamp(),
  kind text NOT NULL,
  executor_type text NOT NULL,
  executor_id text,
  executor_name text,
  source text NOT NULL,
  status text NOT NULL,
  operation_status text,
  reason_code text,
  target_type text,
  target_id uuid,
  attempt integer NOT NULL DEFAULT 1 CHECK(attempt BETWEEN 1 AND 1000000),
  details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(details)='object'),
  UNIQUE(operation_id,id),
  FOREIGN KEY(operation_id,parent_event_id) REFERENCES audit_events(operation_id,id)
);
CREATE INDEX IF NOT EXISTS audit_operations_created_idx ON audit_operations(created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS audit_operations_initiator_idx ON audit_operations(initiator_id,created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS audit_operations_short_id_idx ON audit_operations(initiator_short_id,created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS audit_operations_target_idx ON audit_operations(target_type,target_id,created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS audit_operations_action_idx ON audit_operations(action,created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS audit_operations_recipient_idx ON audit_operations(recipient_id,recipient_type,created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS audit_events_operation_idx ON audit_events(operation_id,id);
CREATE INDEX IF NOT EXISTS audit_events_created_idx ON audit_events(created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS audit_events_target_idx ON audit_events(target_type,target_id,operation_id);
CREATE TABLE IF NOT EXISTS audit_deleted_operations(id uuid PRIMARY KEY);
CREATE TABLE IF NOT EXISTS audit_deleted_events(id bigint PRIMARY KEY,operation_id uuid NOT NULL);
CREATE OR REPLACE FUNCTION system_audit_lock(operation uuid,exclusive boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF exclusive THEN PERFORM pg_advisory_xact_lock(hashtextextended('system_audit:'||operation::text,0));
  ELSE PERFORM pg_advisory_xact_lock_shared(hashtextextended('system_audit:'||operation::text,0)); END IF;
END $$;
CREATE OR REPLACE FUNCTION system_audit_normalize_insert() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE operation uuid;
BEGIN
  IF TG_TABLE_NAME='audit_operations' THEN operation:=NEW.id; ELSE operation:=NEW.operation_id; END IF;
  PERFORM system_audit_lock(operation);
  IF EXISTS(SELECT 1 FROM audit_deleted_operations WHERE id=operation) THEN
    IF TG_TABLE_NAME='audit_operations' THEN RAISE EXCEPTION 'Deleted audit operation cannot be recreated' USING ERRCODE='23505'; END IF;
    RETURN NULL;
  END IF;
  IF TG_TABLE_NAME='audit_events' THEN
    IF EXISTS(SELECT 1 FROM audit_deleted_events WHERE id=NEW.parent_event_id AND operation_id=operation)
      THEN NEW.parent_event_id:=NULL; END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS system_audit_normalize_insert ON audit_operations;
CREATE TRIGGER system_audit_normalize_insert BEFORE INSERT ON audit_operations
  FOR EACH ROW EXECUTE FUNCTION system_audit_normalize_insert();
DROP TRIGGER IF EXISTS system_audit_normalize_insert ON audit_events;
CREATE TRIGGER system_audit_normalize_insert BEFORE INSERT ON audit_events
  FOR EACH ROW EXECUTE FUNCTION system_audit_normalize_insert();
CREATE OR REPLACE FUNCTION system_audit_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'System audit events are append-only'; END $$;
CREATE OR REPLACE FUNCTION system_audit_event_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE mode text:=current_setting('app.audit_delete_mode',true);
  operation text:=current_setting('app.audit_delete_operation',true);
  event text:=current_setting('app.audit_delete_event',true);
BEGIN
  IF OLD.operation_id::text=operation THEN
    IF TG_OP='DELETE' AND (mode='operation' OR (mode='event' AND OLD.id::text=event)) THEN RETURN OLD; END IF;
    IF TG_OP='UPDATE' AND mode='event' AND OLD.parent_event_id::text=event AND NEW.parent_event_id IS NULL
      AND (to_jsonb(NEW)-'parent_event_id')=(to_jsonb(OLD)-'parent_event_id') THEN RETURN NEW; END IF;
  END IF;
  RAISE EXCEPTION 'System audit events are append-only';
END $$;
DROP TRIGGER IF EXISTS system_audit_immutable ON audit_events;
CREATE TRIGGER system_audit_immutable BEFORE UPDATE OR DELETE ON audit_events
  FOR EACH ROW EXECUTE FUNCTION system_audit_event_guard();
DROP TRIGGER IF EXISTS system_audit_no_truncate ON audit_events;
CREATE TRIGGER system_audit_no_truncate BEFORE TRUNCATE ON audit_events
  FOR EACH STATEMENT EXECUTE FUNCTION system_audit_immutable();
DROP TRIGGER IF EXISTS system_audit_metadata_immutable ON audit_metadata;
CREATE TRIGGER system_audit_metadata_immutable BEFORE UPDATE OR DELETE ON audit_metadata
  FOR EACH ROW EXECUTE FUNCTION system_audit_immutable();
DROP TRIGGER IF EXISTS system_audit_metadata_no_truncate ON audit_metadata;
CREATE TRIGGER system_audit_metadata_no_truncate BEFORE TRUNCATE ON audit_metadata
  FOR EACH STATEMENT EXECUTE FUNCTION system_audit_immutable();
DROP TRIGGER IF EXISTS system_audit_deleted_operations_immutable ON audit_deleted_operations;
CREATE TRIGGER system_audit_deleted_operations_immutable BEFORE UPDATE OR DELETE ON audit_deleted_operations
  FOR EACH ROW EXECUTE FUNCTION system_audit_immutable();
DROP TRIGGER IF EXISTS system_audit_deleted_operations_no_truncate ON audit_deleted_operations;
CREATE TRIGGER system_audit_deleted_operations_no_truncate BEFORE TRUNCATE ON audit_deleted_operations
  FOR EACH STATEMENT EXECUTE FUNCTION system_audit_immutable();
DROP TRIGGER IF EXISTS system_audit_deleted_events_immutable ON audit_deleted_events;
CREATE TRIGGER system_audit_deleted_events_immutable BEFORE UPDATE OR DELETE ON audit_deleted_events
  FOR EACH ROW EXECUTE FUNCTION system_audit_immutable();
DROP TRIGGER IF EXISTS system_audit_deleted_events_no_truncate ON audit_deleted_events;
CREATE TRIGGER system_audit_deleted_events_no_truncate BEFORE TRUNCATE ON audit_deleted_events
  FOR EACH STATEMENT EXECUTE FUNCTION system_audit_immutable();
CREATE OR REPLACE FUNCTION system_audit_projection_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.id::text=current_setting('app.audit_delete_operation',true) THEN
    IF TG_OP='DELETE' AND current_setting('app.audit_delete_mode',true)='operation' THEN RETURN OLD; END IF;
    IF TG_OP='UPDATE' AND current_setting('app.audit_delete_mode',true)='event'
      AND (to_jsonb(NEW)-ARRAY['event_count','updated_at','duration_ms','status','status_source','reason_code',
        'media_type','capture_kind','recipient_type','recipient_id','recipient_name','recipient_short_id'])=
        (to_jsonb(OLD)-ARRAY['event_count','updated_at','duration_ms','status','status_source','reason_code',
        'media_type','capture_kind','recipient_type','recipient_id','recipient_name','recipient_short_id']) THEN RETURN NEW; END IF;
  END IF;
  IF TG_OP='DELETE' OR pg_trigger_depth()<2 THEN
    RAISE EXCEPTION 'System audit operations are maintained by events';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS system_audit_projection_guard ON audit_operations;
CREATE TRIGGER system_audit_projection_guard BEFORE UPDATE OR DELETE ON audit_operations
  FOR EACH ROW EXECUTE FUNCTION system_audit_projection_guard();
DROP TRIGGER IF EXISTS system_audit_operations_no_truncate ON audit_operations;
CREATE TRIGGER system_audit_operations_no_truncate BEFORE TRUNCATE ON audit_operations
  FOR EACH STATEMENT EXECUTE FUNCTION system_audit_immutable();
CREATE OR REPLACE FUNCTION system_audit_preserve_outcome(previous_kind text,next_kind text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT (next_kind='http_response' AND previous_kind IN ('scan_workflow_finished','scan_queue_removed',
      'message_request_accepted','contact_request_status_changed','contact_request_removed')) OR
    (next_kind='scan_queue_removed' AND previous_kind='scan_workflow_finished') OR
    (next_kind='contact_request_removed' AND previous_kind IN ('message_request_accepted','contact_request_status_changed'))
$$;
CREATE OR REPLACE FUNCTION system_audit_project_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE media text; capture text; recipient_kind text; recipient uuid; recipient_label text; recipient_short text;
BEGIN
  IF NEW.kind IN('upload_context','dispatch_context','operation_started') THEN
    IF NEW.details->>'mediaType' IN ('video','image','audio','document') THEN media:=NEW.details->>'mediaType'; END IF;
    IF (media='video' AND NEW.details->>'captureKind'='camera_video')
      OR (media='image' AND NEW.details->>'captureKind'='camera_image')
      OR (media='audio' AND NEW.details->>'captureKind'='microphone') THEN capture:=NEW.details->>'captureKind'; END IF;
    IF NEW.details->>'recipientType' IN ('user','group')
      AND NEW.details->>'recipientId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      recipient_kind:=NEW.details->>'recipientType';
      IF recipient_kind='user' THEN
        SELECT u.id,u.name,to_jsonb(u)->>'short_id' INTO recipient,recipient_label,recipient_short
          FROM users u WHERE u.id=(NEW.details->>'recipientId')::uuid;
      ELSE
        SELECT g.id,g.name,to_jsonb(g)->>'short_id' INTO recipient,recipient_label,recipient_short
          FROM groups g WHERE g.id=(NEW.details->>'recipientId')::uuid;
      END IF;
      IF recipient IS NULL THEN recipient_kind:=NULL; END IF;
    END IF;
  END IF;
  UPDATE audit_operations SET event_count=event_count+1,
    root_event_id=COALESCE(root_event_id,NEW.id),
    updated_at=GREATEST(updated_at,NEW.created_at),
    status=CASE WHEN system_audit_preserve_outcome(status_source,NEW.kind) THEN status
      ELSE COALESCE(NEW.operation_status,status) END,
    status_source=CASE WHEN NEW.operation_status IS NULL OR system_audit_preserve_outcome(status_source,NEW.kind)
      THEN status_source ELSE NEW.kind END,
    reason_code=CASE WHEN NEW.operation_status IS NULL OR system_audit_preserve_outcome(status_source,NEW.kind)
      THEN reason_code ELSE NEW.reason_code END,
    media_type=COALESCE(media_type,media),
    capture_kind=CASE WHEN media_type IS NULL OR media_type=media THEN COALESCE(capture_kind,capture) ELSE capture_kind END,
    recipient_type=CASE WHEN recipient_id IS NULL THEN COALESCE(recipient_kind,recipient_type) ELSE recipient_type END,
    recipient_name=CASE WHEN recipient_id IS NULL AND recipient IS NOT NULL THEN recipient_label ELSE recipient_name END,
    recipient_short_id=CASE WHEN recipient_id IS NULL AND recipient IS NOT NULL THEN recipient_short ELSE recipient_short_id END,
    recipient_id=COALESCE(recipient_id,recipient),
    duration_ms=GREATEST(duration_ms,GREATEST(0,(extract(epoch FROM (NEW.created_at-created_at))*1000)::bigint))
    WHERE id=NEW.operation_id;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS system_audit_project_event ON audit_events;
CREATE TRIGGER system_audit_project_event AFTER INSERT ON audit_events
  FOR EACH ROW EXECUTE FUNCTION system_audit_project_event();
CREATE OR REPLACE FUNCTION system_audit_rebuild_operation(operation uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE original audit_operations; evidence audit_events; outcome text; outcome_source text; reason text;
  remaining_count bigint; last_at timestamptz; keep_media boolean; keep_capture boolean; keep_recipient boolean;
BEGIN
  SELECT * INTO STRICT original FROM audit_operations WHERE id=operation;
  SELECT * INTO STRICT evidence FROM audit_events WHERE operation_id=operation AND id=original.root_event_id;
  outcome:=COALESCE(evidence.operation_status,evidence.status); outcome_source:=evidence.kind; reason:=evidence.reason_code;
  FOR evidence IN SELECT * FROM audit_events WHERE operation_id=operation ORDER BY id LOOP
    IF evidence.operation_status IS NOT NULL AND NOT system_audit_preserve_outcome(outcome_source,evidence.kind) THEN
      outcome:=evidence.operation_status; outcome_source:=evidence.kind; reason:=evidence.reason_code;
    END IF;
  END LOOP;
  SELECT count(*),GREATEST(original.created_at,max(created_at)) INTO remaining_count,last_at FROM audit_events WHERE operation_id=operation;
  SELECT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=operation AND kind IN('upload_context','dispatch_context','operation_started')
    AND details->>'mediaType'=original.media_type) INTO keep_media;
  SELECT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=operation AND kind IN('upload_context','dispatch_context','operation_started')
    AND details->>'mediaType'=original.media_type AND details->>'captureKind'=original.capture_kind) INTO keep_capture;
  SELECT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=operation AND kind IN('upload_context','dispatch_context','operation_started')
    AND details->>'recipientType'=original.recipient_type AND lower(details->>'recipientId')=original.recipient_id::text) INTO keep_recipient;
  UPDATE audit_operations SET event_count=remaining_count,updated_at=last_at,
    duration_ms=GREATEST(0,(extract(epoch FROM (last_at-created_at))*1000)::bigint),
    status=outcome,status_source=outcome_source,reason_code=reason,
    media_type=CASE WHEN keep_media THEN media_type END,capture_kind=CASE WHEN keep_capture THEN capture_kind END,
    recipient_type=CASE WHEN keep_recipient THEN recipient_type END,recipient_id=CASE WHEN keep_recipient THEN recipient_id END,
    recipient_name=CASE WHEN keep_recipient THEN recipient_name END,recipient_short_id=CASE WHEN keep_recipient THEN recipient_short_id END
    WHERE id=operation;
END $$;
INSERT INTO audit_metadata(key) VALUES('recording_started') ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION system_audit_safe_code(value text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN value ~ '^[a-zA-Z][a-zA-Z0-9_.:-]{0,79}$' THEN value END
$$;
CREATE OR REPLACE FUNCTION system_audit_business_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE row_data jsonb; old_data jsonb; operation uuid; parent bigint; event_kind text;
  event_status text:='completed'; event_operation_status text; event_source text:='database_trigger';
  entity_type text; entity uuid; event_attempt integer:=1; safe_details jsonb:='{}'::jsonb;
  context_operation text; context_parent text; reason text; policy_key text; side text; previous_outcome_source text;
BEGIN
  IF TG_OP='DELETE' AND TG_TABLE_NAME NOT IN ('pending_scans','message_requests','contact_requests') THEN RETURN NULL; END IF;
  row_data:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  old_data:=CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
  operation:=NULLIF(row_data->>'audit_operation_id','')::uuid;
  parent:=NULLIF(row_data->>'audit_parent_event_id','')::bigint;
  IF TG_TABLE_NAME='message_status' THEN
    SELECT m.audit_operation_id,m.audit_parent_event_id INTO operation,parent
      FROM messages m WHERE m.id=(row_data->>'message_id')::uuid;
  END IF;
  IF (TG_TABLE_NAME='stored_files' AND TG_OP='UPDATE') OR
    (operation IS NULL AND TG_TABLE_NAME='filter_audit_events') THEN
    operation:=NULL; parent:=NULL;
    context_operation:=current_setting('app.audit_operation_id',true);
    context_parent:=current_setting('app.audit_parent_event_id',true);
    IF context_operation ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      operation:=context_operation::uuid;
      IF context_parent ~ '^[1-9][0-9]{0,18}$' AND context_parent::numeric<=9223372036854775807 THEN
        parent:=context_parent::bigint;
      END IF;
    END IF;
  END IF;
  IF operation IS NULL THEN RETURN NULL; END IF;
  IF TG_OP='DELETE' THEN SELECT status_source INTO previous_outcome_source FROM audit_operations WHERE id=operation; END IF;
  IF TG_TABLE_NAME='stored_files' THEN
    IF TG_OP='INSERT' THEN event_kind:='media_stored';
    ELSIF row_data->'moderation_status' IS DISTINCT FROM old_data->'moderation_status'
      OR row_data->'moderation_details'->'classification' IS DISTINCT FROM old_data->'moderation_details'->'classification'
      THEN event_kind:='media_moderation_changed';
    ELSE RETURN NULL; END IF;
    entity_type:='file'; entity:=(row_data->>'id')::uuid;
    safe_details:=jsonb_strip_nulls(jsonb_build_object('fileType',system_audit_safe_code(row_data->>'file_type'),
      'previousStatus',system_audit_safe_code(old_data->>'moderation_status'),
      'moderationStatus',system_audit_safe_code(row_data->>'moderation_status')));
    event_status:=CASE row_data->>'moderation_status' WHEN 'pending' THEN 'pending'
      WHEN 'rejected' THEN 'blocked' WHEN 'stopped' THEN 'failed' ELSE 'completed' END;
    reason:=CASE WHEN row_data->>'moderation_status'='stopped' THEN 'scan_stopped'
      ELSE system_audit_safe_code(row_data->'moderation_details'->>'blockedBy') END;
  ELSIF TG_TABLE_NAME='pending_scans' THEN
    entity_type:='scan';
    safe_details:=jsonb_strip_nulls(jsonb_build_object('queueId',row_data->>'id',
      'fileType',system_audit_safe_code(row_data->>'file_type')));
    event_attempt:=GREATEST(1,LEAST(1000000,COALESCE((row_data->>'retry_count')::integer,0)));
    IF TG_OP='INSERT' THEN event_kind:='scan_queued'; event_status:='pending';
    ELSIF TG_OP='DELETE' THEN
      event_kind:='scan_queue_removed'; event_status:='observed';
      IF previous_outcome_source='scan_workflow_finished' THEN reason:='queue_entry_removed';
      ELSE event_operation_status:='cancelled'; reason:='queue_removed_without_scan_outcome'; END IF;
    ELSIF row_data->'retry_count' IS DISTINCT FROM old_data->'retry_count'
      AND COALESCE((row_data->>'retry_count')::integer,0)>COALESCE((old_data->>'retry_count')::integer,0)
      THEN event_kind:='scan_attempt_started'; event_status:='running';
    ELSE RETURN NULL; END IF;
  ELSIF TG_TABLE_NAME='messages' THEN
    entity_type:='message'; entity:=(row_data->>'id')::uuid;
    IF TG_OP='INSERT' THEN event_kind:='message_persisted';
    ELSIF row_data->'delivery_summary' IS DISTINCT FROM old_data->'delivery_summary'
      THEN event_kind:='message_delivery_state_changed';
    ELSE RETURN NULL; END IF;
    safe_details:=jsonb_strip_nulls(jsonb_build_object('messageType',system_audit_safe_code(row_data->>'type')));
    IF jsonb_typeof(row_data->'delivery_summary'->'deliveredTo')='array' THEN
      safe_details:=safe_details||jsonb_build_object('deliveredCount',jsonb_array_length(row_data->'delivery_summary'->'deliveredTo'));
    END IF;
    IF jsonb_typeof(row_data->'delivery_summary'->'blockedFor')='array' THEN
      safe_details:=safe_details||jsonb_build_object('blockedCount',jsonb_array_length(row_data->'delivery_summary'->'blockedFor'));
    END IF;
  ELSIF TG_TABLE_NAME='message_status' THEN
    IF TG_OP='UPDATE' AND row_data->'status' IS NOT DISTINCT FROM old_data->'status' THEN RETURN NULL; END IF;
    event_kind:='server_message_status_changed'; event_status:='observed';
    reason:='server_state_not_device_ack';
    entity_type:='message'; entity:=(row_data->>'message_id')::uuid;
    safe_details:=jsonb_strip_nulls(jsonb_build_object('recipientId',row_data->>'user_id',
      'previousStatus',system_audit_safe_code(old_data->>'status'),'nextStatus',system_audit_safe_code(row_data->>'status')));
  ELSIF TG_TABLE_NAME IN ('contact_requests','message_requests') THEN
    entity_type:='contact_request'; entity:=(row_data->>'id')::uuid;
    IF TG_OP='INSERT' THEN event_kind:='contact_request_pending'; event_status:='pending';
    ELSIF TG_OP='DELETE' THEN
      event_kind:='contact_request_removed'; event_status:='observed';
      IF previous_outcome_source IN ('message_request_accepted','contact_request_status_changed') THEN reason:='request_entry_removed';
      ELSE event_operation_status:='cancelled'; reason:='request_removed_without_acceptance'; END IF;
    ELSIF row_data->'status' IS DISTINCT FROM old_data->'status' THEN
      event_kind:='contact_request_status_changed';
      event_operation_status:=CASE row_data->>'status' WHEN 'accepted' THEN 'completed'
        WHEN 'approved' THEN 'completed' WHEN 'rejected' THEN 'blocked'
        WHEN 'declined' THEN 'blocked' WHEN 'cancelled' THEN 'cancelled' END;
      event_status:=COALESCE(event_operation_status,'observed');
    ELSE RETURN NULL; END IF;
    safe_details:=jsonb_strip_nulls(jsonb_build_object('messageType',system_audit_safe_code(row_data->>'type'),
      'previousStatus',system_audit_safe_code(old_data->>'status'),'nextStatus',system_audit_safe_code(row_data->>'status')));
  ELSIF TG_TABLE_NAME='filter_audit_events' THEN
    IF TG_OP<>'INSERT' THEN RETURN NULL; END IF;
    event_kind:=system_audit_safe_code(row_data->>'kind');
    IF event_kind IS NULL THEN RETURN NULL; END IF;
    event_source:='filter_db';
    entity_type:=system_audit_safe_code(row_data->>'scope_type');
    entity:=NULLIF(row_data->>'scope_id','')::uuid;
    reason:=system_audit_safe_code(row_data->'details'->>'reasonCode');
    event_status:=CASE WHEN event_kind IN ('decision_blocked','delivery_blocked_persisted') THEN 'blocked' ELSE 'completed' END;
    safe_details:=jsonb_strip_nulls(jsonb_build_object('messageId',row_data->>'message_id',
      'storedFileId',row_data->>'file_id','reasonCode',reason,
      'messageType',system_audit_safe_code(row_data->'details'->>'messageType')));
    FOREACH side IN ARRAY ARRAY['before','after'] LOOP
      FOREACH policy_key IN ARRAY ARRAY['text','video','men','women','children','nonHumanImages','enforceGeneralFilter'] LOOP
        IF jsonb_typeof(row_data->'details'->side->policy_key)='boolean' THEN
          safe_details:=safe_details||jsonb_build_object(side||upper(left(policy_key,1))||substr(policy_key,2),
            row_data->'details'->side->policy_key);
        END IF;
      END LOOP;
    END LOOP;
  ELSE RETURN NULL; END IF;
  INSERT INTO audit_events(operation_id,parent_event_id,kind,executor_type,source,status,operation_status,reason_code,
    target_type,target_id,attempt,details)
    VALUES(operation,parent,event_kind,'system',event_source,event_status,event_operation_status,reason,entity_type,entity,event_attempt,safe_details);
  RETURN NULL;
END $$;
DO $$ DECLARE table_name text; BEGIN
  FOREACH table_name IN ARRAY ARRAY['stored_files','pending_scans','messages','contact_requests','message_requests','filter_audit_events','message_status'] LOOP
    IF EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname=current_schema() AND c.relname=table_name AND c.relkind IN ('r','p')) THEN
      IF table_name<>'message_status' THEN
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS audit_operation_id uuid',current_schema(),table_name);
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS audit_parent_event_id bigint',current_schema(),table_name);
      END IF;
      EXECUTE format('DROP TRIGGER IF EXISTS system_audit_business_event ON %I.%I',current_schema(),table_name);
      EXECUTE format('CREATE TRIGGER system_audit_business_event AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION system_audit_business_event()',current_schema(),table_name);
    END IF;
  END LOOP;
END $$;
`;

function fail(message, code = 'INVALID_AUDIT_INPUT') {
  return Object.assign(new TypeError(message), { status: 400, code });
}
function uuid(value, name, optional = true) {
  if (value == null && optional) return null;
  if (typeof value !== 'string' || !UUID.test(value)) throw fail(`Invalid ${name}`);
  return value.toLowerCase();
}
function code(value, name, fallback = null) {
  const result = value == null ? fallback : value;
  if (result == null) return null;
  if (typeof result !== 'string' || !CODE.test(result)) throw fail(`Invalid ${name}`);
  return result;
}
function eventId(value) {
  if (value == null) return null;
  const text = String(value);
  if (!/^[1-9]\d{0,18}$/.test(text) || BigInt(text) > 9223372036854775807n) throw fail('Invalid event ID');
  return text;
}
function executor(data, inherited = {}) {
  const type = data.executorType ?? inherited.executorType ?? 'system';
  if (!EXECUTORS.has(type)) throw fail('Invalid executor type');
  const id = data.executorId !== undefined ? data.executorId : inherited.executorId ?? null;
  if (id != null && (typeof id !== 'string' || !/^[a-zA-Z0-9_.:-]{1,100}$/.test(id))) throw fail('Invalid executor ID');
  if (['user', 'admin', 'client'].includes(type) && id != null) uuid(id, 'executor ID');
  return { type, id };
}
function runWithAuditContext(value, callback) {
  if (typeof callback !== 'function') throw new TypeError('Audit callback is required');
  const safe = { ...value };
  if (safe.operationId != null) safe.operationId = uuid(safe.operationId, 'operation ID');
  if (safe.parentEventId != null) safe.parentEventId = eventId(safe.parentEventId);
  if (safe.initiatorId != null) safe.initiatorId = uuid(safe.initiatorId, 'initiator ID');
  return context.run(Object.freeze(safe), callback);
}
function getAuditContext() { return context.getStore() || null; }
async function ensureSystemAuditSchema(db) { await db.query(SYSTEM_AUDIT_SQL); await db.query(DISPATCH_SQL); await db.query(COST_SQL); }

async function beginOperation(db, data) {
  const inherited = getAuditContext() || {};
  const id = uuid(data.id ?? randomUUID(), 'operation ID', false);
  const action = code(data.action, 'action');
  if (!action) throw fail('Action is required');
  const category = code(data.category, 'category', lookupAction(action)?.category || 'other');
  const initiatorId = uuid(data.initiatorId !== undefined ? data.initiatorId : inherited.initiatorId, 'initiator ID');
  const actor = executor(data, inherited);
  const source = code(data.source, 'source', inherited.source || 'server');
  const status = code(data.status, 'status', 'running');
  const reason = code(data.reasonCode, 'reason code');
  const targetType = code(data.targetType, 'target type');
  const targetId = uuid(data.targetId, 'target ID');
  const details = JSON.stringify(sanitizeAuditDetails(data.details));
  const result = await db.query(`WITH operation AS (
      INSERT INTO audit_operations(id,action,category,initiator_id,initiator_name,initiator_short_id,
        target_type,target_id,source,status,reason_code)
      SELECT $1,$2,$3,$4,u.name,to_jsonb(u)->>'short_id',$5,$6,$7,$8,$9
      FROM (SELECT 1) seed LEFT JOIN users u ON u.id=$4::uuid RETURNING *
    ), first_event AS (
      INSERT INTO audit_events(operation_id,kind,executor_type,executor_id,executor_name,source,status,
        operation_status,reason_code,target_type,target_id,details)
      SELECT o.id,'operation_started',$10,$11,
        (SELECT name FROM users WHERE id=$12::uuid),$7,$8,$8,$9,$5,$6,$13::jsonb
      FROM operation o RETURNING id
    ) SELECT o.*,e.id AS root_event_id,1::bigint AS event_count
      FROM operation o CROSS JOIN first_event e`, [id,action,category,initiatorId,targetType,targetId,
    source,status,reason,actor.type,actor.id,actor.id && UUID.test(actor.id) ? actor.id : null,details]);
  return result.rows[0];
}

async function recordAuditEvent(db, data) {
  const inherited = getAuditContext() || {};
  const operationId = uuid(data.operationId ?? inherited.operationId, 'operation ID', false);
  const parentId = eventId(data.parentEventId !== undefined ? data.parentEventId : inherited.parentEventId);
  const actor = executor(data, inherited);
  const attempt = data.attempt ?? 1;
  if (!Number.isInteger(attempt) || attempt < 1 || attempt > 1000000) throw fail('Invalid attempt');
  const kind = code(data.kind, 'event kind');
  if (!kind) throw fail('Event kind is required');
  const result = await db.query(`INSERT INTO audit_events(operation_id,parent_event_id,kind,executor_type,
      executor_id,executor_name,source,status,operation_status,reason_code,target_type,target_id,attempt,details)
    VALUES($1,$2,$3,$4,$5,(SELECT name FROM users WHERE id=$6::uuid),$7,$8,$9,$10,$11,$12,$13,$14::jsonb)
    RETURNING *`, [operationId,parentId,kind,actor.type,actor.id,
    actor.id && UUID.test(actor.id) ? actor.id : null,
    code(data.source,'source',inherited.source || 'server'),code(data.status,'status','completed'),
    code(data.operationStatus,'operation status'),code(data.reasonCode,'reason code'),
    code(data.targetType,'target type'),uuid(data.targetId,'target ID'),attempt,
    JSON.stringify(sanitizeAuditDetails(data.details))]);
  return result.rows[0];
}

function deletionError(message,status,code) { return Object.assign(new Error(message),{status,code}); }
async function deleteAuditRecordInTransaction(client,{mode,id,actorId,audit=true}) {
    let operationId=id;
    if (mode==='event') {
      const event=await client.query('SELECT operation_id FROM audit_events WHERE id=$1',[id]);
      if (!event.rows.length) throw deletionError('Audit event not found',404,'AUDIT_EVENT_NOT_FOUND');
      operationId=event.rows[0].operation_id;
    }
    await client.query('SELECT system_audit_lock($1::uuid,true)',[operationId]);
    const operation=(await client.query('SELECT * FROM audit_operations WHERE id=$1 FOR UPDATE',[operationId])).rows[0];
    if (!operation) throw deletionError('Audit operation not found',404,'AUDIT_OPERATION_NOT_FOUND');
    if (mode==='event') {
      const event=await client.query('SELECT id FROM audit_events WHERE id=$1 AND operation_id=$2 FOR UPDATE',[id,operationId]);
      if (!event.rows.length) throw deletionError('Audit event not found',404,'AUDIT_EVENT_NOT_FOUND');
      if (String(operation.root_event_id)===id)
        throw deletionError('Delete the entire operation to remove its root event',409,'AUDIT_ROOT_EVENT');
    }
    await client.query(`SELECT set_config('app.audit_delete_mode',$1,true),
      set_config('app.audit_delete_operation',$2,true),set_config('app.audit_delete_event',$3,true)`,
    [mode,operationId,mode==='event'?id:'']);
    let deletedEvents;
    if (mode==='operation') {
      await client.query('INSERT INTO audit_deleted_operations(id) VALUES($1)',[operationId]);
      deletedEvents=(await client.query('DELETE FROM audit_events WHERE operation_id=$1',[operationId])).rowCount;
      await client.query('DELETE FROM audit_operations WHERE id=$1',[operationId]);
    } else {
      await client.query('INSERT INTO audit_deleted_events(id,operation_id) VALUES($1,$2)',[id,operationId]);
      await client.query('UPDATE audit_events SET parent_event_id=NULL WHERE operation_id=$1 AND parent_event_id=$2',[operationId,id]);
      deletedEvents=(await client.query('DELETE FROM audit_events WHERE operation_id=$1 AND id=$2',[operationId,id])).rowCount;
      await client.query('SELECT system_audit_rebuild_operation($1::uuid)',[operationId]);
    }
    await client.query(`SELECT set_config('app.audit_delete_mode','',true),
      set_config('app.audit_delete_operation','',true),set_config('app.audit_delete_event','',true)`);
    if(audit)await beginOperation(client,{action:mode==='operation'?'audit_delete_operation':'audit_delete_event',
      category:'administration',initiatorId:actorId,executorType:'admin',executorId:actorId,source:'admin',status:'completed',
      targetType:'audit_operation',targetId:operationId,details:{affectedCount:deletedEvents,auditOperationId:operationId,
        ...(mode==='event'?{auditEventId:id}:{})}});
    return {deleted:true,operationId,deletedEvents};
}
async function deleteAuditRecord(pool,{mode,id,actorId}) {
  if (!['operation','event'].includes(mode)) throw fail('Invalid audit deletion mode');
  id=mode==='operation'?uuid(id,'operation ID',false):eventId(id);
  if (!id) throw fail('Invalid event ID');
  actorId=uuid(actorId,'administrator ID',false);
  const client=await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL lock_timeout='10s'; SET LOCAL statement_timeout='30s'");
    const result=await deleteAuditRecordInTransaction(client,{mode,id,actorId});
    await client.query('COMMIT');
    return result;
  } catch(error) {
    await client.query('ROLLBACK').catch(()=>{});
    throw error;
  } finally { client.release(); }
}


async function deleteAuditRecords(pool,{scope,operations=[],events=[],through,confirm,actorId}) {
  if(!['selected','all'].includes(scope)||confirm!==(scope==='all'?'DELETE_ALL_AUDIT':'DELETE_SELECTED_AUDIT'))
    throw fail('Explicit bulk deletion confirmation required','AUDIT_DELETE_CONFIRMATION_REQUIRED');
  actorId=uuid(actorId,'administrator ID',false);
  if(!Array.isArray(operations)||!Array.isArray(events)||operations.length+events.length>200||
      (scope==='selected'&&!operations.length&&!events.length))throw fail('Select between 1 and 200 records');
  operations=[...new Set(operations.map(id=>uuid(id,'operation ID',false)))];
  events=[...new Set(events.map(id=>{const value=eventId(id);if(!value)throw fail('Invalid event ID');return value;}))];
  if(scope==='all'){through=eventId(through);if(!through||operations.length||events.length)throw fail('Invalid deletion boundary');}
  const client=await pool.connect();
  try{
    await client.query('BEGIN');await client.query("SET LOCAL lock_timeout='10s'; SET LOCAL statement_timeout='30s'");
    if(scope==='all')operations=(await client.query('SELECT id FROM audit_operations WHERE root_event_id<=$1::bigint ORDER BY id LIMIT 100',[through])).rows.map(row=>row.id);
    const selectedEvents=events.length?(await client.query('SELECT id,operation_id FROM audit_events WHERE id=ANY($1::bigint[])',[events])).rows:[];
    const targets=[...operations.map(id=>({mode:'operation',id,operationId:id})),
      ...selectedEvents.filter(row=>!operations.includes(row.operation_id)).map(row=>({mode:'event',id:row.id,operationId:row.operation_id}))]
      .sort((a,b)=>a.operationId.localeCompare(b.operationId)||a.id.localeCompare(b.id));
    let deletedOperations=0,deletedEvents=0;
    for(const target of targets){
      try{const result=await deleteAuditRecordInTransaction(client,{...target,actorId,audit:false});deletedEvents+=result.deletedEvents;if(target.mode==='operation')deletedOperations++;}
      catch(error){if(error.status!==404)throw error;}
    }
    const remaining=scope==='all'?(await client.query('SELECT count(*) FROM audit_operations WHERE root_event_id<=$1::bigint',[through])).rows[0].count:'0';
    if(deletedOperations||deletedEvents)await beginOperation(client,{action:'audit_delete_records',category:'administration',initiatorId:actorId,executorType:'admin',executorId:actorId,source:'admin',status:'completed',details:{affectedCount:deletedEvents}});
    await client.query('COMMIT');return {deleted:true,deletedOperations,deletedEvents,remaining};
  }catch(error){await client.query('ROLLBACK').catch(()=>{});throw error;}finally{client.release();}
}

function encodeCursor(row, mode, filters = {}) {
  if (filters.sort) return Buffer.from(JSON.stringify({v:2,id:String(row.id),
    sort:filters.sort,direction:filters.direction,value:row.audit_sort_value==null?null:
      row.audit_sort_value instanceof Date?row.audit_sort_value.toISOString():String(row.audit_sort_value)})).toString('base64url');
  const value = mode === 'operations' ? { v: 1, createdAt: new Date(row.created_at).toISOString(), id: row.id }
    : { v: 1, id: String(row.id) };
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}
function parseTime(value, name) {
  if (typeof value !== 'string' || value.length > 40 || !/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(value)) throw fail(`Invalid ${name}`);
  const time = Date.parse(value);
  if (!Number.isFinite(time)) throw fail(`Invalid ${name}`);
  return new Date(time).toISOString();
}
const COLUMN_FILTERS = {
  operations: {
    created_at:'date',action:'text',display_action:'text',kind:'text',initiator_id:'uuid',executor_id:'text',target_type:'text',target_id:'uuid',
    source:'text',status:'text',reason_code:'text',event_count:'number',duration_ms:'number',
    media_type:'text',capture_kind:'text',recipient_type:'text',recipient_id:'uuid',
    check_type:'text',check_outcome:'text',
  },
  events: {
    created_at:'date',display_action:'text',kind:'text',initiator_id:'uuid',executor_id:'text',target_type:'text',target_id:'uuid',
    source:'text',status:'text',reason_code:'text',duration_ms:'number',attempt:'number',operation_id:'uuid',parent_event_id:'bigint',
    media_type:'text',capture_kind:'text',recipient_type:'text',recipient_id:'uuid',
    check_type:'text',check_outcome:'text',
  },
};
for(const mode of ['operations','events'])for(const [key,[type]]of Object.entries(EXTENDED_FIELDS))COLUMN_FILTERS[mode][key]=type;
const OPERATION_CONTEXT_COLUMNS = new Set(['display_action','duration_ms','initiator_id','media_type','capture_kind','recipient_type','recipient_id']);
const CHECK_COLUMNS = new Set(['check_type','check_outcome']);
const CHAIN_COLUMNS = new Set(['action','kind','status','source','target_type','target_id','reason_code', ...CHECK_COLUMNS]);
// Displayed action is derived only from recorded media context, exactly as in the web table.
// Keep raw action filters unchanged for older clients and general upload queries.
const DISPLAY_ACTION_LABELS = {
  'capture:camera_video':'צילום וידאו', 'capture:camera_image':'צילום תמונה',
  'capture:microphone':'הקלטת קול', 'media:video':'העלאת וידאו',
  'media:image':'העלאת תמונה', 'media:audio':'העלאת קובץ קול', 'media:document':'העלאת מסמך',
};
function displayActionSql(alias) {
  return `(CASE WHEN ${alias}.action='upload_file' THEN
    CASE WHEN ${alias}.media_type='video' AND ${alias}.capture_kind='camera_video' THEN 'capture:camera_video'
      WHEN ${alias}.media_type='image' AND ${alias}.capture_kind='camera_image' THEN 'capture:camera_image'
      WHEN ${alias}.media_type='audio' AND ${alias}.capture_kind='microphone' THEN 'capture:microphone'
      WHEN ${alias}.media_type IN ('video','image','audio','document') THEN 'media:'||${alias}.media_type
      ELSE ${alias}.action END ELSE ${alias}.action END)`;
}
function auditColumnSql(alias, column, mode='operations') {
  if(hasExtendedField(column))return extendedFieldSql(alias,column,mode);
  if (column === 'display_action') return displayActionSql(alias);
  if (column === 'check_type') return alias === 'e' ? checkTypeSql(alias) : `${alias}.${column}`;
  if (column === 'check_outcome') return alias === 'e' ? checkOutcomeSql(alias) : `${alias}.${column}`;
  return `${alias}.${column}`;
}
function isChainColumn(filters,column) {
  return stepField(column,'operations') || column==='kind' || column==='executor_id' || CHECK_COLUMNS.has(column) ||
    (['chain','items'].includes(filters.match) && CHAIN_COLUMNS.has(column) && !(filters.steps && column==='action'));
}
function chainRowsSql(steps=false) {
  if(steps)return `SELECT linked.kind AS action,linked.status,linked.source,linked.target_type,linked.target_id,linked.reason_code,
    ${checkTypeSql('linked')} AS check_type,${checkOutcomeSql('linked')} AS check_outcome,linked.kind,linked.executor_id,linked.executor_name,linked.id,linked.created_at,linked.details,linked.parent_event_id,linked.attempt,linked.executor_type
    FROM audit_events linked WHERE linked.operation_id=o.id AND linked.id IS DISTINCT FROM o.root_event_id`;

  return `SELECT o.action,o.status,o.source,o.target_type,o.target_id,o.reason_code,
    NULL::text AS check_type,NULL::text AS check_outcome,NULL::text AS kind,NULL::text AS executor_id,NULL::text AS executor_name,NULL::bigint AS id,NULL::timestamptz AS created_at,NULL::jsonb AS details,NULL::bigint AS parent_event_id,NULL::integer AS attempt,NULL::text AS executor_type
    UNION ALL SELECT linked.kind,linked.status,linked.source,linked.target_type,linked.target_id,linked.reason_code,
      ${checkTypeSql('linked')},${checkOutcomeSql('linked')},linked.kind,linked.executor_id,linked.executor_name,linked.id,linked.created_at,linked.details,linked.parent_event_id,linked.attempt,linked.executor_type
    FROM audit_events linked WHERE linked.operation_id=o.id AND linked.id IS DISTINCT FROM o.root_event_id`;
}
function filterObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function numericBound(value) {
  if (typeof value !== 'string' || !/^(?:0|[1-9]\d{0,18})$/.test(value) || BigInt(value)>9223372036854775807n)
    throw fail('Invalid numeric column filter');
  return value;
}
function decimalBound(value){
 if(typeof value!=='string'||!/^\d{1,12}(\.\d{1,12})?$/.test(value))throw fail('Invalid decimal column filter');return value;
}
function readColumnFilters(value, mode) {
  if (value === undefined) return {};
  if (typeof value !== 'string' || Buffer.byteLength(value,'utf8')>16384) throw fail('Invalid column filters');
  let input;
  try { input=JSON.parse(value); } catch { throw fail('Invalid column filters'); }
  if (!filterObject(input)) throw fail('Invalid column filters');
  const result={};
  for (const [column,filter] of Object.entries(input)) {
    const type=Object.hasOwn(COLUMN_FILTERS[mode],column) ? COLUMN_FILTERS[mode][column] : null;
    if (!type || !filterObject(filter)) throw fail('Invalid column filter');
    const allowed=type==='date' ? ['from','to'] : (type==='number'||type==='decimal') ? ['min','max'] : ['values','exclude'];
    if (Object.keys(filter).some(key=>!allowed.includes(key))) throw fail('Invalid column filter fields');
    if (type==='date' || type==='number' || type==='decimal') {
      const [lower,upper]=allowed;
      const range={};
      for (const name of allowed) if (filter[name]!==undefined)
        range[name]=type==='date' ? parseTime(filter[name],`column ${name}`) : type==='decimal'?decimalBound(filter[name]):numericBound(filter[name]);
      if (!Object.keys(range).length) throw fail('Empty column range');
      if (range[lower]!==undefined && range[upper]!==undefined && (type==='date'
        ? range[lower]>range[upper] : type==='decimal'?Number(range[lower])>Number(range[upper]):BigInt(range[lower])>BigInt(range[upper]))) throw fail('Invalid column range');
      result[column]=range;
      continue;
    }
    if (!Array.isArray(filter.values) || filter.values.length>100 ||
      (filter.exclude!==undefined && typeof filter.exclude!=='boolean')) throw fail('Invalid column values');
    const values=filter.values.map(item=>{
      if (item===null) return null;
      if (typeof item!=='string' || item.length>(column==='dispatch_reason'||column==='dispatch_file_name'?500:200)) throw fail('Invalid column value');
      if (type==='uuid') return uuid(item,'column UUID',false);
      if (type==='bigint') return eventId(item);
      return item;
    });
    result[column]={values:[...new Set(values)],exclude:filter.exclude===true};
  }
  return result;
}
function readFilters(query = {}, { mode = 'operations', exportMode = false } = {}) {
  if (typeof mode!=='string' || !Object.hasOwn(COLUMN_FILTERS,mode)) throw fail('Invalid audit mode');
  const result = { mode,columnFilters:readColumnFilters(query.columnFilters,mode) };
  if(query.previews!==undefined){if(query.previews!=='1')throw fail('Invalid preview view');result.previews=true;}
  if(query.costs!==undefined){if(query.costs!=='1')throw fail('Invalid usage view');result.costs=true;}
  if(query.dispatch!==undefined){if(query.dispatch!=='1')throw fail('Invalid dispatch view');result.dispatch=true;}
  if(query.steps!==undefined){if(query.steps!=='1')throw fail('Invalid step view');result.steps=true;}
  if (query.sort !== undefined) {
    if (typeof query.sort !== 'string' || !Object.hasOwn(COLUMN_FILTERS[mode],query.sort)) throw fail('Invalid sort column');
    if (!['asc','desc'].includes(query.direction)) throw fail('Invalid sort direction');
    result.sort=query.sort;result.direction=query.direction;
  } else if (query.direction !== undefined) throw fail('Missing sort column');
  for (const [name,allowed] of [['scope',['all','user']],['match',['root','chain','items']]]) {
    if (query[name]!==undefined) {
      if (typeof query[name]!=='string' || !allowed.includes(query[name])) throw fail(`Invalid audit ${name}`);
      result[name]=query[name];
    }
  }
  for (const name of ['action','status','category','targetType','source','reasonCode']) {
    if (query[name] !== undefined && query[name] !== '') result[name] = code(query[name],name);
  }
  if (query.targetId) result.targetId = uuid(query.targetId,'target ID',false);
  if (query.userId) {
    if (typeof query.userId !== 'string' || !(UUID.test(query.userId) || /^[1-9]\d{0,11}$/.test(query.userId))) throw fail('Invalid user ID');
    result.userId = query.userId;
  }
  if (query.from) result.from = parseTime(query.from,'from');
  if (query.to) result.to = parseTime(query.to,'to');
  if (result.from && result.to && result.from > result.to) throw fail('Invalid date range');
  if (exportMode && (!result.from || !result.to || Date.parse(result.to)-Date.parse(result.from) > 31*86400000))
    throw fail('Export requires an explicit date range of at most 31 days','AUDIT_EXPORT_RANGE_REQUIRED');
  if (query.limit !== undefined && (typeof query.limit !== 'string' || !/^\d{1,4}$/.test(query.limit))) throw fail('Invalid limit');
  result.limit = exportMode ? 5000 : Math.max(1,Math.min(200,Number(query.limit) || 50));
  if (query.before) {
    if (typeof query.before !== 'string' || query.before.length > 2048 || !/^[A-Za-z0-9_-]+$/.test(query.before)) throw fail('Invalid cursor');
    let cursor;
    try { cursor = JSON.parse(Buffer.from(query.before,'base64url').toString()); } catch { throw fail('Invalid cursor'); }
    if (result.sort) {
      if (cursor?.v!==2 || cursor.sort!==result.sort || cursor.direction!==result.direction ||
          !(cursor.value===null || typeof cursor.value==='string' && cursor.value.length<=500)) throw fail('Invalid sort cursor');
      if(cursor.value!==null){
        const type=COLUMN_FILTERS[mode][result.sort];
        if(type==='date')cursor.value=parseTime(cursor.value,'sort date');
        if(type==='number'||type==='bigint')cursor.value=numericBound(cursor.value);
        if(type==='decimal')cursor.value=decimalBound(cursor.value);
        if(type==='uuid'&&!['initiator_id','recipient_id'].includes(result.sort))cursor.value=uuid(cursor.value,'sort ID',false);
      }
      result.before={id:mode==='operations'?uuid(cursor.id,'cursor ID',false):eventId(cursor.id),value:cursor.value};
      return result;
    }
    if (cursor?.v !== 1) throw fail('Invalid cursor');
    result.before = mode === 'operations' ? { id: uuid(cursor.id,'cursor ID',false),createdAt:parseTime(cursor.createdAt,'cursor date') }
      : { id:eventId(cursor.id) };
    if (!result.before.id) throw fail('Invalid cursor');
  }
  return result;
}
function buildWhere(filters, operationId = null, { omitColumn=null,ignoreCursor=false,chainAlias=null } = {}) {
  const events = filters.mode === 'events';
  const chain = !events && ['chain','items'].includes(filters.match);
  const values = [], where = [];
  const chainWhere=[];
  const add = (sql,value) => { values.push(value); where.push(sql.replaceAll('?',`$${values.length}`)); };
  const addChain=(sql,value)=>{values.push(value);chainWhere.push(sql.replaceAll('?',`$${values.length}`));};
  const matchAlias=chainAlias || 'chain_match';
  if (filters.scope==='user') where.push(`o.initiator_id IS NOT NULL
    AND o.action NOT IN ('report_message_read','register_device') AND EXISTS(SELECT 1 FROM audit_events root_actor
    WHERE root_actor.operation_id=o.id AND root_actor.id=o.root_event_id
    AND root_actor.executor_type IN ('user','admin','client') AND lower(root_actor.executor_id)=o.initiator_id::text)`);
  for (const [key,column] of [['action','action'],['category','category'],['status','status'],
    ['source','source'],['reasonCode','reason_code']]) {
    if (!filters[key]) continue;
    if (chain && column!=='action' && CHAIN_COLUMNS.has(column)) addChain(`${matchAlias}.${column}=?`,filters[key]);
    else add(`${events && !['action','category'].includes(column)?'e':'o'}.${column}=?`,filters[key]);
  }
  if (chain) {
    for (const [key,column] of [['targetType','target_type'],['targetId','target_id']])
      if (filters[key]) addChain(`${matchAlias}.${column}=?`,filters[key]);
  } else if (filters.targetType || filters.targetId) {
    const target=[];
    for (const [key,column] of [['targetType','target_type'],['targetId','target_id']]) {
      if (filters[key]) { values.push(filters[key]); target.push(`${column}=$${values.length}`); }
    }
    const matching = alias=>target.map(term=>`${alias}.${term}`).join(' AND ');
    where.push(events ? `(${matching('e')})` : `((${matching('o')}) OR EXISTS(SELECT 1 FROM audit_events linked
      WHERE linked.operation_id=o.id AND ${matching('linked')}))`);
  }
  if (filters.userId) add(UUID.test(filters.userId) ? 'o.initiator_id=?::uuid' : 'o.initiator_short_id=?',filters.userId);
  const dateColumn = events ? 'e.created_at' : 'o.created_at';
  if (filters.from) add(`${dateColumn}>=?::timestamptz`,filters.from);
  if (filters.to) add(`${dateColumn}<?::timestamptz`,filters.to);
  for (const [column,filter] of Object.entries(filters.columnFilters || {})) {
    if (column===omitColumn) continue;
    if (!Object.hasOwn(COLUMN_FILTERS[filters.mode],column)) throw fail('Invalid column filter');
    const type=COLUMN_FILTERS[filters.mode][column];
    const chainColumn=!events && isChainColumn(filters,column);
    const negativeChain=chainColumn && filter.exclude && filters.match!=='items';
    const sqlColumn=auditColumnSql(chainColumn ? negativeChain?'chain_excluded':matchAlias
      : events && !OPERATION_CONTEXT_COLUMNS.has(column)&&!parentField(column,filters.mode)?'e':'o',column,filters.mode);
    const predicates=chainColumn ? [] : where;
    if (type==='date') {
      if (filter.from!==undefined) add(`${sqlColumn}>=?::timestamptz`,filter.from);
      if (filter.to!==undefined) add(`${sqlColumn}<?::timestamptz`,filter.to);
    } else if (type==='number'||type==='decimal') {
      const numericType=type==='decimal'?'numeric':'bigint';
      if (filter.min!==undefined) (chainColumn?addChain:add)(`${sqlColumn}>=?::${numericType}`,filter.min);
      if (filter.max!==undefined) (chainColumn?addChain:add)(`${sqlColumn}<=?::${numericType}`,filter.max);
    } else {
      const nonNull=filter.values.filter(value=>value!==null);
      const hasNull=filter.values.includes(null);
      const exclude=filter.exclude && !negativeChain;
      if (!filter.values.length) {
        if (!filter.exclude) predicates.push('FALSE');
      } else if (!nonNull.length) {
        predicates.push(`${sqlColumn} IS ${exclude?'NOT ':''}NULL`);
      } else {
        values.push(nonNull);
        const matching=`${sqlColumn} ${exclude?'<> ALL':'= ANY'}($${values.length}::${type}[])`;
        const nullClause=exclude && hasNull ? `AND ${sqlColumn} IS NOT NULL`
          : !exclude && !hasNull ? '' : `OR ${sqlColumn} IS NULL`;
        predicates.push(`(${matching}${nullClause?' '+nullClause:''})`);
      }
      if (negativeChain && predicates.length) where.push(`NOT EXISTS(SELECT 1 FROM (${chainRowsSql(filters.steps)}) chain_excluded
        WHERE ${predicates.join(' AND ')})`);
      else if (chainColumn) chainWhere.push(...predicates);
    }
  }
  if (chainWhere.length) where.push(chainAlias ? `(${chainWhere.join(' AND ')})`
    : `EXISTS(SELECT 1 FROM (${chainRowsSql(filters.steps)}) ${matchAlias} WHERE ${chainWhere.join(' AND ')})`);
  if (operationId) add('e.operation_id=?::uuid',operationId);
  if (filters.before && !ignoreCursor && !filters.sort) {
    if (events) add('e.id<?::bigint',filters.before.id);
    else {
      values.push(filters.before.createdAt,filters.before.id);
      where.push(`(o.created_at,o.id)<($${values.length-1}::timestamptz,$${values.length}::uuid)`);
    }
  }
  return { values,where:where.length?' WHERE '+where.join(' AND '):'' };
}
function rawBuildQuery(filters, operationId = null) {
  const events=filters.mode==='events';
  const {values,where}=buildWhere(filters,operationId);
  let eventSource='audit_events';
  if(events&&filters.steps){
    if(!operationId)throw fail('Step events require an operation');
    values.push(operationId);eventSource=rankedStepSource(`child.operation_id=$${values.length}::uuid`);
  }
  values.push(filters.limit+1);const limitIndex=values.length;
  const costSelect=costsEnabled(filters)?`${usageSql('o.id')} AS operation_usage,${events?usageSql('o.id','e.id')+' AS usage,':''}`:'';
  const sql = events ? `SELECT e.*,${costSelect}o.action AS operation_action,o.category,
    o.initiator_id,o.initiator_name,o.initiator_short_id,o.root_event_id,o.created_at AS operation_created_at,o.duration_ms AS operation_duration_ms,o.status AS current_operation_status,o.reason_code AS current_operation_reason_code,o.status_source AS current_operation_status_source,
    o.media_type,o.capture_kind,o.recipient_type,o.recipient_id,o.recipient_name,o.recipient_short_id FROM ${eventSource} e
    JOIN audit_operations o ON o.id=e.operation_id` : `SELECT o.*${costSelect?','+costSelect.slice(0,-1):''} FROM audit_operations o`;
  let selected;
  if (filters.sort) {
    const column=filters.sort,alias=events&&!OPERATION_CONTEXT_COLUMNS.has(column)&&!parentField(column,filters.mode)?'e':'o';
    let expression=!events&&(CHECK_COLUMNS.has(column)||column==='kind'||stepField(column,'operations'))
      ? `(SELECT min(${auditColumnSql('e',column)}) FROM audit_events e WHERE e.operation_id=o.id${column==='kind'||stepField(column,'operations')?' AND e.id IS DISTINCT FROM o.root_event_id':''})`
      : auditColumnSql(alias,column,filters.mode);
    if(!events&&stepField(column,'operations')){
      // Order groups by the same first matching step shown in the collapsed row.
      const child=buildWhere({mode:'events',columnFilters:stepColumnFilters(filters)}),offset=values.length;
      const childWhere=child.where.replace(/\$(\d+)/g,(_,index)=>'$'+(Number(index)+offset)).replace(/^ WHERE /,' AND ');values.push(...child.values);
      expression=`(SELECT ${auditColumnSql('e',column,'operations')} FROM audit_events e
        WHERE e.operation_id=o.id AND e.id IS DISTINCT FROM o.root_event_id${childWhere}
        ORDER BY date_trunc('milliseconds',e.created_at),e.id LIMIT 1)`;
    }
    if(hasExtendedField(column)&&EXTENDED_FIELDS[column][0]==='text'){
      const label=fieldLabelSql(column,'sort_value');if(label!=='sort_value')expression=`(SELECT ${label} FROM (SELECT ${expression} AS sort_value OFFSET 0) sort_display)`;
    }
    let type=COLUMN_FILTERS[filters.mode][column];
    if(['initiator_id','recipient_id','executor_id'].includes(column)){
      expression=!events&&column==='executor_id'
        ? `(SELECT min(COALESCE(NULLIF(e.executor_name,''),e.executor_id)) FROM audit_events e WHERE e.operation_id=o.id AND e.id IS DISTINCT FROM o.root_event_id)`
        : `COALESCE(NULLIF(${alias}.${column.replace('_id','_name')},''),${alias}.${column}::text)`;type='text';
    }
    if(type==='date')expression=`date_trunc('milliseconds',${expression})`;
    const cast=type==='date'?'timestamptz':type==='number'?'bigint':type==='decimal'?'numeric':type;
    const direction=filters.direction==='asc'?'ASC':'DESC',comparison=direction==='ASC'?'>':'<';
    let after='';
    if (filters.before) {
      values.push(filters.before.id);const id=`$${values.length}::${events?'bigint':'uuid'}`;
      if (filters.before.value===null) after=` WHERE audit_sort_value IS NULL AND id${comparison}${id}`;
      else {
        values.push(filters.before.value);const value=`$${values.length}::${cast}`;
        after=` WHERE (audit_sort_value${comparison}${value} OR audit_sort_value IS NULL OR (audit_sort_value=${value} AND id${comparison}${id}))`;
      }
    }
    selected=`SELECT * FROM (${sql.replace('SELECT ',()=>`SELECT ${expression} AS audit_sort_value,`)}${where}) sorted${after}
      ORDER BY audit_sort_value ${direction} NULLS LAST,id ${direction} LIMIT $${limitIndex}`;
  } else selected=`${sql}${where} ORDER BY ${events?'e.id DESC':'o.created_at DESC,o.id DESC'} LIMIT $${values.length}`;
  if (!events && (filters.scope==='user' || ['chain','items'].includes(filters.match))) return {text:`SELECT o.*,
    summary.sub_event_count,latest.kind AS latest_event_kind,latest.status AS latest_event_status,
    latest.created_at AS latest_event_at FROM (${selected}) o
    CROSS JOIN LATERAL (SELECT count(*) AS sub_event_count FROM audit_events child
      WHERE child.operation_id=o.id AND child.id IS DISTINCT FROM o.root_event_id) summary
    LEFT JOIN LATERAL (SELECT kind,status,created_at FROM audit_events child
      WHERE child.operation_id=o.id AND child.id IS DISTINCT FROM o.root_event_id ORDER BY child.id DESC LIMIT 1) latest ON true
    ORDER BY ${filters.sort?`o.audit_sort_value ${filters.direction==='asc'?'ASC':'DESC'} NULLS LAST,o.id ${filters.direction==='asc'?'ASC':'DESC'}`:'o.created_at DESC,o.id DESC'}`,values};
  return { text:selected,values };
}
// Rank the complete operation before filters or pagination, preserving bigint precision.
function rankedStepSource(predicate) {
  return `(SELECT child.*,row_number() OVER(PARTITION BY child.operation_id ORDER BY date_trunc('milliseconds',child.created_at),child.id)::text AS sub_event_index,
    count(*) OVER(PARTITION BY child.operation_id)::text AS sub_event_total
    FROM audit_events child JOIN audit_operations owner ON owner.id=child.operation_id
    WHERE ${predicate} AND child.id IS DISTINCT FROM owner.root_event_id)`;
}
function stepColumnFilters(filters) {
  const columnFilters={};
  for(const [field,value]of Object.entries(filters.columnFilters||{})){
    if(['action','display_action','event_count','duration_ms'].includes(field)||parentField(field,'operations'))continue;
    columnFilters[field]=value;
  }
  return columnFilters;
}
function rawBuildFirstStepQuery(filters,operationIds) {
  const columnFilters=stepColumnFilters(filters);
  const eventFilters={mode:'events',columnFilters};
  const {values,where}=buildWhere(eventFilters);
  values.push(operationIds);
  return {text:`SELECT DISTINCT ON(e.operation_id) e.*,${costsEnabled(filters)?usageSql('o.id','e.id')+' AS usage,':''}o.root_event_id,o.action AS operation_action,
    o.media_type,o.capture_kind,o.recipient_type,o.recipient_id,o.recipient_name,o.recipient_short_id
    FROM ${rankedStepSource(`child.operation_id=ANY($${values.length}::uuid[])`)} e
    JOIN audit_operations o ON o.id=e.operation_id${where}
    ORDER BY e.operation_id,date_trunc('milliseconds',e.created_at),e.id`,values};
}
// Outcome evidence is independent of child filters and pagination. Keep budget
// evidence inside the current scan attempt, even when a generic terminal follows it.
function buildOperationOutcomeQuery(operationIds) {
  return {text:`SELECT o.id AS operation_id,o.status,o.status_source,
    to_jsonb(outcome) AS outcome_event,to_jsonb(scan) AS scan_summary
    FROM audit_operations o
    ${OPERATION_OUTCOME_JOINS}
    WHERE o.id=ANY($1::uuid[])`,values:[operationIds]};
}

function rawBuildFilterOptionsQuery(filters,column,search='') {
  const type=typeof column==='string' && Object.hasOwn(COLUMN_FILTERS[filters.mode],column)
    ? COLUMN_FILTERS[filters.mode][column] : null;
  if (!type || type==='date' || type==='number' || type==='decimal') throw fail('Invalid filter options column');
  if (typeof search!=='string' || search.length>100) throw fail('Invalid filter options search');
  const events=filters.mode==='events';
  const chainColumn=!events && isChainColumn(filters,column);
  const {values,where}=buildWhere(filters,null,{omitColumn:column,ignoreCursor:true,chainAlias:chainColumn?'chain_option':null});
  const sqlColumn=auditColumnSql(chainColumn?'chain_option':events && !OPERATION_CONTEXT_COLUMNS.has(column)&&!parentField(column,filters.mode)?'e':'o',column,filters.mode);
  let label=`${sqlColumn}::text`;
  const labels=column==='status' ? Object.fromEntries(STATUSES.map(row=>[row.code,row.label]))
    : column==='action' ? {...(chainColumn?EVENT_KIND_LABELS:{}),...Object.fromEntries(ACTION_CATALOG.map(row=>[row.action,row.label]))}
    : column==='display_action' ? {...Object.fromEntries(ACTION_CATALOG.map(row=>[row.action,row.label])),...DISPLAY_ACTION_LABELS}
    : column==='kind' ? EVENT_KIND_LABELS
    : column==='check_type' ? CHECK_TYPE_LABELS
    : column==='check_outcome' ? CHECK_OUTCOME_LABELS : null;
  if (labels) {
    values.push(JSON.stringify(labels));
    label=`COALESCE($${values.length}::jsonb ->> ${sqlColumn},${sqlColumn}::text)`;
  }
  if (column==='initiator_id') label=`concat_ws(' / ',NULLIF(o.initiator_name,''),
    CASE WHEN o.initiator_short_id IS NOT NULL THEN 'ID '||o.initiator_short_id END,o.initiator_id::text)`;
  if (column==='executor_id') {const alias=chainColumn?'chain_option':'e';label=`concat_ws(' / ',NULLIF(${alias}.executor_name,''),${alias}.executor_id)`;}
  if (column==='recipient_id') label=`concat_ws(' / ',CASE o.recipient_type WHEN 'group' THEN 'קבוצה' WHEN 'user' THEN 'משתמש' END,
    NULLIF(o.recipient_name,''),CASE WHEN o.recipient_short_id IS NOT NULL THEN 'ID '||o.recipient_short_id END,o.recipient_id::text)`;
  if (column==='recipient_type') label=`CASE ${sqlColumn} WHEN 'user' THEN 'משתמש' WHEN 'group' THEN 'קבוצה' ELSE ${sqlColumn} END`;
  if (column==='media_type') label=`CASE ${sqlColumn} WHEN 'video' THEN 'וידאו' WHEN 'image' THEN 'תמונה'
    WHEN 'audio' THEN 'שמע' WHEN 'document' THEN 'מסמך' ELSE ${sqlColumn} END`;
  if (column==='capture_kind') label=`CASE ${sqlColumn} WHEN 'camera_video' THEN 'צילום וידאו' WHEN 'camera_image' THEN 'צילום תמונה'
    WHEN 'microphone' THEN 'הקלטת שמע' ELSE ${sqlColumn} END`;
  if(hasExtendedField(column)||column==='target_type')label=`(${fieldLabelSql(column,sqlColumn)})::text`;
  const from=events ? 'audit_events e JOIN audit_operations o ON o.id=e.operation_id'
    : `audit_operations o${chainColumn?` CROSS JOIN LATERAL (${chainRowsSql(filters.steps)}) chain_option`:''}`;
  let searchWhere='';
  if (search) {
    values.push('%'+search.replace(/[\\%_]/g,'\\$&')+'%');
    searchWhere=` WHERE value ILIKE $${values.length} ESCAPE E'\\\\' OR label ILIKE $${values.length} ESCAPE E'\\\\'`;
  }
  if(hasExtendedField(column)){
    // Translate distinct scalar values once, rather than reevaluating outcome subqueries per label clause.
    const displayed=fieldLabelSql(column,'value');
    return {text:`SELECT value,label FROM (SELECT value,CASE WHEN value IS NULL THEN '(ריק)' ELSE (${displayed})::text END AS label
      FROM (SELECT DISTINCT (${sqlColumn})::text AS value FROM ${from}${where}) audit_values) audit_options${searchWhere}
      ORDER BY value NULLS FIRST LIMIT 101`,values};
  }
  return {text:`SELECT value,max(label) AS label FROM (
    SELECT ${sqlColumn}::text AS value,CASE WHEN ${sqlColumn} IS NULL THEN '(ריק)' ELSE ${label} END AS label
    FROM ${from}${where}) audit_options${searchWhere}
    GROUP BY value ORDER BY value NULLS FIRST LIMIT 101`,values};
}
function buildQuery(filters,operationId=null){return wrapDispatchQuery(rawBuildQuery(filters,operationId),filters,operationId?[operationId]:undefined);}
function buildFirstStepQuery(filters,ids){return wrapDispatchQuery(rawBuildFirstStepQuery(filters,ids),filters,ids);}
function buildFilterOptionsQuery(filters,column,search=''){return wrapDispatchQuery(rawBuildFilterOptionsQuery(filters,column,search),{...filters,dispatch:filters.dispatch||Object.hasOwn(DISPATCH_FIELDS,column)||column==='stopped_file'});}
async function metadata(db) {
  const result = await db.query("SELECT created_at FROM audit_metadata WHERE key='recording_started'");
  return { recordingStartedAt:result.rows[0]?.created_at || null,coverage:COVERAGE };
}
function csvCell(value) {
  let text = value == null ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value);
  if (/^[\s\uFEFF]*[=+@-]/.test(text) || /^[\t\r\n]/.test(text)) text = "'"+text;
  return '"'+text.replaceAll('"','""')+'"';
}
function registerSystemAuditRoutes(app, { getPool, adminMiddleware }) {
  if (typeof adminMiddleware !== 'function') throw new TypeError('Admin middleware is required');
  const route = (path,handler,method='get') => app[method](path,adminMiddleware,async(req,res) => {
    res.set('Cache-Control','no-store');
    if (!req.user?.id || !UUID.test(req.user.id)) return res.status(401).json({error:'Authentication required',code:'AUDIT_AUTH_REQUIRED'});
    try { return await handler(req,res,await getPool()); }
    catch (error) {
      if ([400,403,404,409].includes(error.status)) return res.status(error.status).json({error:error.message,code:error.code});
      console.error('[system-audit] Request failed:',error.code || error.name);
      return res.status(503).json({error:'Audit data is temporarily unavailable',code:'AUDIT_UNAVAILABLE'});
    }
  });
  route('/api/admin/audit/catalog',async(req,res,db) => {
    const categories = CATEGORIES || [...new Set(ACTION_CATALOG.map(row=>row.category))].map(code=>({code,label:code}));
    return res.json({actions:ACTION_CATALOG,categories,statuses:STATUSES || FALLBACK_STATUSES,
      eventKinds:EVENT_KIND_LABELS,canDelete:req.adminPerm==='edit',
      defaultColumnFilters:{display_action:{values:['media:video','media:image'],exclude:false}},
      ...await metadata(db)});
  });
  const list = mode => async(req,res,db) => {
    const operationId = req.params?.id ? uuid(req.params.id,'operation ID',false) : null;
    const filters = readFilters(req.query,{mode});
    if(costsEnabled(filters))await refreshFx();
    if (operationId && !(await db.query('SELECT 1 FROM audit_operations WHERE id=$1',[operationId])).rows.length)
      return res.status(404).json({error:'Operation not found',code:'AUDIT_OPERATION_NOT_FOUND'});
    const query = buildQuery(filters,operationId);
    const prepared=await prepareDispatchQuery(db,query);
    const result = await db.query(prepared.text,prepared.values);
    const rows = result.rows.slice(0,filters.limit).map(row=>presentUsage(presentDispatch(presentAuditCheck(row))));
    if(mode==='operations'&&filters.steps&&rows.length){
      const firstQuery=buildFirstStepQuery(filters,rows.map(row=>row.id));
      const firstPrepared=await prepareDispatchQuery(db,firstQuery);
      const firstRows=(await db.query(firstPrepared.text,firstPrepared.values)).rows;
      const firstByOperation=new Map(firstRows.map(row=>[row.operation_id,presentUsage(presentDispatch(presentAuditCheck(row)))]));
      const outcomeQuery=buildOperationOutcomeQuery(rows.map(row=>row.id));
      const outcomeRows=(await db.query(outcomeQuery.text,outcomeQuery.values)).rows;
      const outcomeByOperation=new Map(outcomeRows.map(row=>[row.operation_id,row]));
      for(const row of rows){
        row.first_sub_event=firstByOperation.get(row.id)||null;
        const outcome=outcomeByOperation.get(row.id);
        for(const key of ['outcome_event','scan_summary']){
          const evidence=outcome?.status===row.status&&outcome?.status_source===row.status_source?outcome[key]:null;
          row[key]=evidence?{...evidence,details:sanitizeAuditDetails(evidence.details)}:null;
        }
      }
    }
    if(filters.previews){
      await attachOperationPreviews(db,rows,mode);
      await attachOperationMedia(db,rows,mode);
      await attachScanImageNames(db,mode==='events'?rows:rows.map(row=>row.first_sub_event).filter(Boolean));
      await attachStoppedScanEvidence(db,rows,mode);
    }
    return res.json({[mode]:rows,nextCursor:result.rows.length>filters.limit?encodeCursor(rows.at(-1),mode,filters):null,...await metadata(db)});
  };
  route('/api/admin/audit/operations',list('operations'));
  route('/api/admin/audit/operations/:id/events',list('events'));
  route('/api/admin/audit/events',list('events'));
  route('/api/admin/audit/deletion-preview',async(req,res,db)=>{
    if(req.adminPerm!=='edit')throw deletionError('Audit deletion requires edit permission',403,'AUDIT_DELETE_FORBIDDEN');
    const row=(await db.query('SELECT max(root_event_id)::text AS through,count(*)::text AS operations,COALESCE(sum(event_count),0)::text AS events FROM audit_operations')).rows[0];
    return res.json(row);
  });
  route('/api/admin/audit/records',async(req,res,db)=>{
    if(req.adminPerm!=='edit')throw deletionError('Audit deletion requires edit permission',403,'AUDIT_DELETE_FORBIDDEN');
    if(!filterObject(req.body))throw fail('Invalid bulk deletion request');
    return res.json(await deleteAuditRecords(db,{...req.body,actorId:req.user.id}));
  },'delete');
  for (const [path,mode] of [['/api/admin/audit/operations/:id','operation'],['/api/admin/audit/events/:id','event']]) {
    route(path,async(req,res,db)=>{
      if (req.adminPerm!=='edit') throw deletionError('Audit deletion requires edit permission',403,'AUDIT_DELETE_FORBIDDEN');
      if (mode==='operation') uuid(req.params?.id,'operation ID',false);
      else if (!eventId(req.params?.id)) throw fail('Invalid event ID');
      if (!filterObject(req.body) || typeof req.body.confirmId!=='string' || req.body.confirmId!==req.params.id)
        throw fail('Exact audit record confirmation is required','AUDIT_DELETE_CONFIRMATION_REQUIRED');
      return res.json(await deleteAuditRecord(db,{mode,id:req.params.id,actorId:req.user.id}));
    },'delete');
  }
  route('/api/admin/audit/filter-options',async(req,res,db)=>{
    const filters=readFilters({...req.query,before:undefined,limit:undefined},{mode:req.query.mode || 'operations'});
    const query=buildFilterOptionsQuery(filters,req.query.column,req.query.search===undefined?'':req.query.search);
    const prepared=await prepareDispatchQuery(db,query);
    const result=await db.query(prepared.text,prepared.values);
    return res.json({options:result.rows.slice(0,100),hasMore:result.rows.length>100});
  });
  route('/api/admin/audit/export.csv',async(req,res,db) => {
    const mode = req.query.mode || 'events';
    if (!['events','operations'].includes(mode)) throw fail('Invalid export mode');
    const filters = readFilters(req.query,{mode,exportMode:true});
    const query = buildQuery(filters);
    const prepared=await prepareDispatchQuery(db,query);
    const result = await db.query(prepared.text,prepared.values);
    const rows = result.rows.slice(0,filters.limit).map(row=>presentUsage(presentDispatch(presentAuditCheck(row))));
    const columns = mode === 'operations' ? ['id','created_at','action','category','initiator_id','initiator_name','initiator_short_id',
      'media_type','capture_kind','recipient_type','recipient_id','recipient_name','recipient_short_id',
      'target_type','target_id','source','status','reason_code','event_count','duration_ms']
      : ['id','operation_id','parent_event_id','created_at','operation_action','category','initiator_id','initiator_name',
        'media_type','capture_kind','recipient_type','recipient_id','recipient_name','recipient_short_id',
        'kind','executor_type','executor_id','executor_name','source','status','reason_code','target_type','target_id','attempt','details'];
    if (mode==='operations' && (filters.scope==='user' || ['chain','items'].includes(filters.match)))
      columns.push('sub_event_count','latest_event_kind','latest_event_status','latest_event_at');
    if(filters.dispatch)columns.push('dispatch');
    if(costsEnabled(filters))columns.push(...Object.keys(COST_FIELDS).filter(key=>mode==='events'||COST_FIELDS[key][1]==='parent'),'operation_usage',...(mode==='events'?['usage']:[]));
    columns.push('check_type','check_outcome','checkLabel','checkResultLabel');
    await beginOperation(db,{action:'audit_export',category:'administration',initiatorId:req.user.id,
      executorType:'admin',executorId:req.user.id,source:'admin',status:'completed',
      details:{affectedCount:rows.length}});
    res.set('Content-Type','text/csv; charset=utf-8');
    res.set('Content-Disposition','attachment; filename="system-audit.csv"');
    res.set('X-Audit-Export-Truncated',String(result.rows.length>filters.limit));
    res.set('X-Audit-Export-Count',String(rows.length));
    return res.send('\uFEFF'+[columns.map(csvCell).join(','),...rows.map(row=>columns.map(key=>csvCell(
      row[key] instanceof Date ? row[key].toISOString() : row[key])).join(','))].join('\r\n')+'\r\n');
  });
}

module.exports = { SYSTEM_AUDIT_SQL, runWithAuditContext, getAuditContext, beginOperation,
  recordAuditEvent, deleteAuditRecord, deleteAuditRecords, ensureSystemAuditSchema, registerSystemAuditRoutes, readFilters, buildQuery, buildFirstStepQuery, buildOperationOutcomeQuery, buildFilterOptionsQuery, csvCell };
