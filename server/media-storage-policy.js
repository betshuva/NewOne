'use strict';

// Archiving a completed scan is independent of permission to send its content.
// Only the owner's personal vault may retain blocked/stopped files.
const ARCHIVABLE_SQL = `(sf.moderation_status='approved'
    AND sf.moderation_details->>'pending' IS DISTINCT FROM 'true'
  OR to_jsonb(sf)->>'storage_tier'='personal'
    AND sf.moderation_status IN ('rejected','stopped'))
  AND NOT EXISTS(SELECT 1 FROM pending_scans ps WHERE ps.file_url=sf.public_url)`;

module.exports = { ARCHIVABLE_SQL };
