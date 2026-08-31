-- Canonical PostgreSQL schema for the BETSHUVA messenger backend.
-- The server also auto-migrates this schema on boot (see the IIFE near the
-- top of server/index.js and initPendingTable()); this file is the
-- reference snapshot of what that migration converges to on a fresh DB.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Users ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                TEXT NOT NULL,
  email               TEXT UNIQUE,
  password_hash       TEXT,
  phone               TEXT,
  email_verified      BOOLEAN NOT NULL DEFAULT FALSE,
  phone_verified      BOOLEAN NOT NULL DEFAULT FALSE,
  city                TEXT,
  country             TEXT,
  street              TEXT,
  house_number        TEXT,
  apartment           TEXT,
  profile_pic_url     TEXT,
  privacy_pic         TEXT NOT NULL DEFAULT 'all',      -- all | contacts | nobody
  filter_level        TEXT NOT NULL DEFAULT 'standard', -- standard | strict
  notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  read_receipts_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  content_filter      JSONB NOT NULL DEFAULT '{"text":true,"video":false,"nonHumanImages":true,"men":false,"women":false,"children":false}'::jsonb,
  google_id           TEXT,
  latitude            DOUBLE PRECISION,
  longitude           DOUBLE PRECISION,
  location_updated_at TIMESTAMPTZ,
  terms_accepted_at   TIMESTAMPTZ,
  terms_version       TEXT,
  age_confirmed       BOOLEAN NOT NULL DEFAULT FALSE,
  gender              TEXT,
  birth_date          DATE,
  wins                INTEGER NOT NULL DEFAULT 0,
  games_played        INTEGER NOT NULL DEFAULT 0,
  referral_count      INTEGER NOT NULL DEFAULT 0,
  created_at          TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS israel_localities (
  code                INTEGER PRIMARY KEY,
  name_he             TEXT NOT NULL,
  district            TEXT,
  subdistrict         TEXT,
  locality_type       TEXT,
  municipal_status    TEXT,
  natural_region      TEXT,
  municipal_cluster   TEXT,
  active              BOOLEAN NOT NULL DEFAULT TRUE,
  source_updated_at   TIMESTAMPTZ,
  synced_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS israel_localities_name_idx
  ON israel_localities(name_he);

CREATE TABLE IF NOT EXISTS israel_streets (
  locality_code INTEGER NOT NULL REFERENCES israel_localities(code)
    ON UPDATE CASCADE ON DELETE CASCADE,
  street_code INTEGER NOT NULL,
  name_he TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY(locality_code,street_code)
);
CREATE INDEX IF NOT EXISTS israel_streets_name_idx
  ON israel_streets(locality_code,name_he);

-- ── Auth Tokens ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS password_reset_tokens (
  token      TEXT PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES users(id),
  expires_at TIMESTAMPTZ NOT NULL,
  used       BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS email_verification_tokens (
  token      TEXT PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES users(id),
  expires_at TIMESTAMPTZ NOT NULL,
  used       BOOLEAN DEFAULT FALSE
);

-- ── Groups ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS groups (
  id               UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name             TEXT NOT NULL,
  description      TEXT,
  creator_id       UUID REFERENCES users(id),
  is_broadcast     BOOLEAN NOT NULL DEFAULT FALSE,   -- שליחה חד-כיוונית
  is_self          BOOLEAN NOT NULL DEFAULT FALSE,   -- קבוצה עצמית מפורשת
  send_permission  TEXT NOT NULL DEFAULT 'all',      -- all | admin
  filter_level     TEXT NOT NULL DEFAULT 'standard', -- standard | strict
  content_filter   JSONB,
  created_at       TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS system_ai_pending_actions (
  user_id    UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  action     TEXT NOT NULL,
  payload    JSONB NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS system_ai_browse_state (
  user_id     UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  browse_type TEXT NOT NULL,
  next_offset INTEGER NOT NULL DEFAULT 0,
  expires_at  TIMESTAMPTZ NOT NULL
);

-- ── Messages ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS messages (
  id                   UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  sender_id            UUID NOT NULL REFERENCES users(id),
  recipient_id         UUID REFERENCES users(id),  -- NULL = group message
  group_id             UUID REFERENCES groups(id),
  type                 TEXT NOT NULL DEFAULT 'text', -- text | image | document | audio
  body                 TEXT,
  file_url             TEXT,
  file_name            TEXT,
  file_size            INTEGER,
  reply_to_id          UUID REFERENCES messages(id),
  deleted_for_sender   BOOLEAN NOT NULL DEFAULT FALSE,
  deleted_for_everyone BOOLEAN NOT NULL DEFAULT FALSE,
  is_edited            BOOLEAN NOT NULL DEFAULT FALSE,
  edited_at            TIMESTAMPTZ,
  delivery_summary     JSONB,
  created_at           TIMESTAMPTZ DEFAULT now()
);

-- ── Message Status (קריאות) ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS message_status (
  message_id UUID NOT NULL REFERENCES messages(id),
  user_id    UUID NOT NULL REFERENCES users(id),
  status     TEXT NOT NULL DEFAULT 'delivered', -- delivered | read
  updated_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

-- הודעות שהוסתרו רק למשתמש מסוים (בצ'אט פרטי או קבוצתי)
CREATE TABLE IF NOT EXISTS message_user_deletions (
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  deleted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

-- ── Groups: membership ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS group_members (
  group_id      UUID NOT NULL REFERENCES groups(id),
  user_id       UUID NOT NULL REFERENCES users(id),
  role          TEXT NOT NULL DEFAULT 'member', -- member | admin
  status        TEXT NOT NULL DEFAULT 'member', -- member | pending
  added_by      UUID,
  pending_since TIMESTAMPTZ,
  filter_override JSONB,
  joined_at     TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (group_id, user_id)
);

-- ── Educational approvals, signatures and surveys ────────────────
CREATE TABLE IF NOT EXISTS education_forms (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  created_by  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  form_type   TEXT NOT NULL CHECK (form_type IN ('approval','signature','survey')),
  title       TEXT NOT NULL,
  description TEXT,
  file_url    TEXT,
  file_name   TEXT,
  questions   JSONB NOT NULL DEFAULT '[]'::jsonb,
  anonymous   BOOLEAN NOT NULL DEFAULT FALSE,
  due_at      TIMESTAMPTZ,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS education_forms_group_idx
  ON education_forms(group_id, created_at DESC);

CREATE TABLE IF NOT EXISTS education_form_recipients (
  form_id     UUID NOT NULL REFERENCES education_forms(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  notified_at TIMESTAMPTZ,
  PRIMARY KEY(form_id,user_id)
);

CREATE TABLE IF NOT EXISTS education_form_responses (
  form_id          UUID NOT NULL REFERENCES education_forms(id) ON DELETE CASCADE,
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  response_status  TEXT NOT NULL CHECK (response_status IN ('approved','declined','completed')),
  answers          JSONB NOT NULL DEFAULT '{}'::jsonb,
  signer_name      TEXT,
  signature_data   JSONB,
  document_version TEXT NOT NULL,
  submitted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY(form_id, user_id)
);

CREATE TABLE IF NOT EXISTS education_form_reminders (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  form_id      UUID NOT NULL REFERENCES education_forms(id) ON DELETE CASCADE,
  sent_by      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  recipient_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sent_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS education_response_change_requests (
  form_id      UUID NOT NULL REFERENCES education_forms(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status       TEXT NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','approved','rejected')),
  requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at   TIMESTAMPTZ,
  decided_by   UUID REFERENCES users(id) ON DELETE SET NULL,
  PRIMARY KEY(form_id,user_id)
);

ALTER TABLE messages ADD COLUMN IF NOT EXISTS education_form_id
  UUID REFERENCES education_forms(id) ON DELETE SET NULL;

-- ── Saved contacts and per-contact filter overrides ─────────────
CREATE TABLE IF NOT EXISTS user_contacts (
  owner_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  contact_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  filter_override JSONB,
  created_at     TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (owner_id, contact_id),
  CHECK (owner_id <> contact_id)
);

-- Invitations to the app. Credit is granted only after the invited identity
-- verifies the phone number or email address used by the inviter.
CREATE TABLE IF NOT EXISTS app_invites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invited_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  email TEXT,
  phone TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  claimed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at TIMESTAMPTZ,
  CHECK (email IS NOT NULL OR phone IS NOT NULL)
);

-- ── Blocked Users ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS blocked_users (
  blocker_id UUID NOT NULL REFERENCES users(id),
  blocked_id UUID NOT NULL REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id)
);

-- ── Audit Log (קבצים שנחסמו) ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    UUID REFERENCES users(id),
  file_name  TEXT,
  file_type  TEXT,
  file_size  INTEGER,
  reason     TEXT,          -- סיבת החסימה מה-AI
  appealed   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ── FCM Tokens (Push Notifications) ───────────────────────────────
CREATE TABLE IF NOT EXISTS fcm_tokens (
  user_id    UUID NOT NULL REFERENCES users(id),
  token      TEXT NOT NULL,
  device_id  TEXT NOT NULL DEFAULT 'default',
  updated_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (user_id, device_id)
);

-- ── Activity Log ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS activity_log (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    UUID REFERENCES users(id),
  action     TEXT NOT NULL,
  details    JSONB,
  ip         TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ── Files stored on the Hetzner server ───────────────────────────
CREATE TABLE IF NOT EXISTS stored_files (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id       UUID REFERENCES users(id) ON DELETE SET NULL,
  original_name TEXT NOT NULL,
  storage_path  TEXT NOT NULL UNIQUE,
  public_url    TEXT NOT NULL UNIQUE,
  mime_type     TEXT,
  file_type     TEXT,
  file_size     BIGINT NOT NULL DEFAULT 0,
  context_type  TEXT,
  context_id    UUID,
  moderation_status TEXT NOT NULL DEFAULT 'pending', -- pending | approved | rejected
  moderation_details JSONB,
  content_sha256 TEXT,
  visual_fingerprint JSONB,
  release_scheduled_at TIMESTAMPTZ,
  released_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS stored_files_content_sha256_idx
  ON stored_files(content_sha256) WHERE content_sha256 IS NOT NULL;

CREATE TABLE IF NOT EXISTS media_classification_appeals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stored_file_id UUID NOT NULL REFERENCES stored_files(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  prior_classification JSONB,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','reviewed','resolved','dismissed')),
  reviewed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  reviewer_note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  reviewed_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS media_classification_appeals_pending_idx
  ON media_classification_appeals(stored_file_id,user_id) WHERE status='pending';

-- Metadata for encrypted backups in storage owned by the user. Nothing here
-- deletes local media; release is enabled only after upload verification.
CREATE TABLE IF NOT EXISTS user_backup_settings (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  provider TEXT CHECK (provider IS NULL OR provider IN ('google_drive')),
  storage_mode TEXT NOT NULL DEFAULT 'backup_only'
    CHECK (storage_mode IN ('backup_only','backup_and_release')),
  wifi_only BOOLEAN NOT NULL DEFAULT TRUE,
  release_threshold_bytes BIGINT NOT NULL DEFAULT 1073741824
    CHECK (release_threshold_bytes >= 0),
  encrypted_data_key TEXT,
  data_key_version INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cloud_backup_accounts (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('google_drive')),
  encrypted_refresh_token TEXT NOT NULL,
  scope TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'connected'
    CHECK (status IN ('connected','error','revoked')),
  last_verified_at TIMESTAMPTZ,
  last_error TEXT,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS media_backup_items (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  stored_file_id UUID NOT NULL REFERENCES stored_files(id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('google_drive')),
  status TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued','uploading','uploaded','verified','failed')),
  remote_file_id TEXT,
  plaintext_sha256 TEXT NOT NULL,
  encrypted_sha256 TEXT,
  encryption_metadata JSONB,
  verified_at TIMESTAMPTZ,
  restore_verified_at TIMESTAMPTZ,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (stored_file_id, provider)
);
CREATE INDEX IF NOT EXISTS media_backup_items_user_status_idx
  ON media_backup_items(user_id, status);

-- System image-scanning conversation bot.
INSERT INTO users(id,name,email,phone,email_verified,phone_verified,city)
VALUES('00000000-0000-4000-8000-000000000001','סריקה','scan@betshuva.system',
       '0000000000',TRUE,TRUE,'מערכת')
ON CONFLICT (id) DO NOTHING;

DROP TRIGGER IF EXISTS users_add_scan_bot_contact ON users;
DROP FUNCTION IF EXISTS add_scan_bot_contact_for_new_user();
DELETE FROM user_contacts
WHERE owner_id='00000000-0000-4000-8000-000000000001'::uuid
   OR contact_id='00000000-0000-4000-8000-000000000001'::uuid;

-- ── App Settings (moderation lists etc.) ──────────────────────────
CREATE TABLE IF NOT EXISTS app_settings (
  key_name   TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ── Admin Permissions ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_permissions (
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  permission TEXT NOT NULL DEFAULT 'view', -- view | edit
  granted_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (user_id)
);

-- ── Games (tic-tac-toe) ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS games (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  player1_id UUID NOT NULL REFERENCES users(id),
  player2_id UUID NOT NULL REFERENCES users(id),
  winner_id  UUID REFERENCES users(id),
  result     TEXT NOT NULL, -- win | tie
  board      TEXT NOT NULL,
  played_at  TIMESTAMPTZ DEFAULT now()
);

-- ── Listings (classifieds board) ──────────────────────────────────
CREATE TABLE IF NOT EXISTS listings (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL,
  type           TEXT NOT NULL DEFAULT 'free', -- free | sale
  title          TEXT NOT NULL,
  description    TEXT,
  price          DOUBLE PRECISION,
  city           TEXT,
  latitude       DOUBLE PRECISION,
  longitude      DOUBLE PRECISION,
  image_url      TEXT,
  category       TEXT,
  item_condition TEXT NOT NULL DEFAULT 'good',
  negotiable     BOOLEAN NOT NULL DEFAULT FALSE,
  quantity       INTEGER NOT NULL DEFAULT 1,
  delivery_method TEXT NOT NULL DEFAULT 'pickup',
  pickup_details TEXT,
  contact_phone_visible BOOLEAN NOT NULL DEFAULT FALSE,
  license_plate  TEXT,
  vehicle_details JSONB,
  property_details JSONB,
  status         TEXT NOT NULL DEFAULT 'active', -- active | sold | expired
  view_count     INTEGER NOT NULL DEFAULT 0,
  contact_count  INTEGER NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ DEFAULT now(),
  expires_at     TIMESTAMPTZ DEFAULT now() + interval '30 days'
);

CREATE TABLE IF NOT EXISTS listing_views (
  listing_id  UUID NOT NULL,
  user_id     UUID NOT NULL,
  viewed_at   TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (listing_id, user_id)
);

CREATE TABLE IF NOT EXISTS listing_images (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id  UUID NOT NULL,
  url         TEXT NOT NULL,
  sort_order  INTEGER NOT NULL DEFAULT 0
);

-- ── Pending Scans (moderation retry queue) ────────────────────────
CREATE TABLE IF NOT EXISTS pending_scans (
  id          INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     UUID NOT NULL,
  to_user_id  UUID,
  group_id    UUID,
  file_url    TEXT NOT NULL,
  file_name   TEXT NOT NULL,
  file_type   TEXT NOT NULL,
  mime_type   TEXT NOT NULL,
  retry_count INTEGER NOT NULL DEFAULT 0,
  last_retry  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ DEFAULT now()
);
