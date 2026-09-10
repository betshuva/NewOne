'use strict';

const { phoneSelect } = require('./contact-phone-privacy');

// These are trusted SQL projections. The caller aliases the target user as u
// and binds the authenticated requester as $1. Phones use the same explicit
// permission or previously known-number policy as the rest of the app.
const guidePhoneSelect = phoneSelect('$1', 'u');

// Preserve the existing locality policy independently from phone sharing.
// Group membership alone grants no city access. Saved contacts, visible private
// conversations and the adult directory remain access paths, respecting both
// sides' blocks and the requester's individual message deletions.
const visibleCityFields = `(u.id=$1 OR (NOT EXISTS (
    SELECT 1 FROM blocked_users phone_block
    WHERE (phone_block.blocker_id=$1 AND phone_block.blocked_id=u.id)
       OR (phone_block.blocker_id=u.id AND phone_block.blocked_id=$1)
  ) AND (
    EXISTS (
      SELECT 1 FROM user_contacts phone_contact
      WHERE phone_contact.owner_id=$1 AND phone_contact.contact_id=u.id
    ) OR EXISTS (
      SELECT 1 FROM messages phone_message
      WHERE phone_message.group_id IS NULL
        AND phone_message.deleted_for_everyone=FALSE
        AND ((phone_message.sender_id=$1 AND phone_message.recipient_id=u.id)
          OR (phone_message.sender_id=u.id AND phone_message.recipient_id=$1))
        AND NOT (phone_message.sender_id=$1
          AND COALESCE(phone_message.deleted_for_sender,FALSE)=TRUE)
        AND NOT EXISTS (
          SELECT 1 FROM message_user_deletions phone_deletion
          WHERE phone_deletion.message_id=phone_message.id AND phone_deletion.user_id=$1
        )
    ) OR (
      u.id NOT IN (
        '00000000-0000-4000-8000-000000000001'::uuid,
        '00000000-0000-4000-8000-000000000002'::uuid,
        '5256aa61-3180-414c-bbf6-a036e8c16248'::uuid
      )
      AND NOT (u.name='משתמש' AND u.gender IS NULL)
      AND (u.email_verified=TRUE OR u.phone_verified=TRUE)
      AND u.birth_date<=CURRENT_DATE-INTERVAL '18 years'
      AND EXISTS (
        SELECT 1 FROM users phone_viewer
        WHERE phone_viewer.id=$1
          AND phone_viewer.birth_date<=CURRENT_DATE-INTERVAL '18 years'
      )
    )
  )))`;

// Deliberately project only the stored locality. Exact coordinates and street
// addresses belong to separate explicit sharing flows and are never read here.
const guideCitySelect = `CASE
  WHEN u.birth_date<=CURRENT_DATE-INTERVAL '18 years' AND ${visibleCityFields}
  THEN NULLIF(BTRIM(u.city),'') ELSE NULL END AS city`;

module.exports = { guidePhoneSelect, guideCitySelect };
