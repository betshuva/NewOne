'use strict';

// Keep the column filter and its evidence tied to the same final file decision.
// An individual provider refusal is not a final rejection.
function problemFileEventSql(operation='o'){
  return `SELECT e.id,e.kind,CASE WHEN e.target_type='file' THEN e.target_id
      WHEN e.details->>'storedFileId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN (e.details->>'storedFileId')::uuid END AS target_id
    FROM audit_events e WHERE e.operation_id=${operation}.id AND (
      (${operation}.status='failed' AND ${operation}.status_source='scan_workflow_finished'
        AND e.kind='scan_workflow_finished' AND e.status='failed' AND e.target_type='file' AND e.target_id IS NOT NULL)
      OR (${operation}.status='blocked' AND e.status='blocked' AND (
        (e.kind='media_moderation_changed' AND e.target_type='file' AND e.target_id IS NOT NULL)
        OR (e.kind='decision_blocked' AND e.details->>'storedFileId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))))
    ORDER BY e.id DESC LIMIT 1`;
}
module.exports={problemFileEventSql};
