-- ── Users ──────────────────────────────────────────────────────────
CREATE TABLE users (
  id              UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
  name            NVARCHAR(100)  NOT NULL,
  email           NVARCHAR(255)  NOT NULL UNIQUE,
  password_hash   NVARCHAR(255)  NOT NULL,
  phone           NVARCHAR(20),
  email_verified  BIT            NOT NULL DEFAULT 0,
  phone_verified  BIT            NOT NULL DEFAULT 0,
  city            NVARCHAR(100),
  community       NVARCHAR(100),
  profile_pic_url NVARCHAR(500),
  privacy_pic     NVARCHAR(20)   NOT NULL DEFAULT 'all',   -- all | contacts | nobody
  filter_level    NVARCHAR(20)   NOT NULL DEFAULT 'standard', -- standard | strict
  created_at      DATETIME       DEFAULT GETDATE()
);

-- ── Auth Tokens ────────────────────────────────────────────────────
CREATE TABLE password_reset_tokens (
  token      NVARCHAR(64)     PRIMARY KEY,
  user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
  expires_at DATETIME         NOT NULL,
  used       BIT              DEFAULT 0
);

CREATE TABLE email_verification_tokens (
  token      NVARCHAR(64)     PRIMARY KEY,
  user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
  expires_at DATETIME         NOT NULL,
  used       BIT              DEFAULT 0
);

-- ── Messages ───────────────────────────────────────────────────────
CREATE TABLE messages (
  id                   UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
  sender_id            UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
  recipient_id         UNIQUEIDENTIFIER REFERENCES users(id),     -- NULL = group message
  group_id             UNIQUEIDENTIFIER,                          -- FK added after groups table
  type                 NVARCHAR(20)  NOT NULL DEFAULT 'text',     -- text | image | document | audio
  body                 NVARCHAR(MAX),                             -- text content
  file_url             NVARCHAR(500),                             -- Azure Blob URL
  file_name            NVARCHAR(255),
  file_size            INT,
  reply_to_id          UNIQUEIDENTIFIER REFERENCES messages(id),
  deleted_for_sender   BIT NOT NULL DEFAULT 0,
  deleted_for_everyone BIT NOT NULL DEFAULT 0,
  created_at           DATETIME DEFAULT GETDATE()
);

-- ── Message Status (קריאות) ────────────────────────────────────────
CREATE TABLE message_status (
  message_id UNIQUEIDENTIFIER NOT NULL REFERENCES messages(id),
  user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
  status     NVARCHAR(20)     NOT NULL DEFAULT 'delivered', -- delivered | read
  updated_at DATETIME         DEFAULT GETDATE(),
  PRIMARY KEY (message_id, user_id)
);

-- ── Groups ─────────────────────────────────────────────────────────
CREATE TABLE groups (
  id               UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
  name             NVARCHAR(100) NOT NULL,
  description      NVARCHAR(500),
  creator_id       UNIQUEIDENTIFIER REFERENCES users(id),
  is_broadcast     BIT          NOT NULL DEFAULT 0,           -- שליחה חד-כיוונית
  send_permission  NVARCHAR(20) NOT NULL DEFAULT 'all',       -- all | admin
  filter_level     NVARCHAR(20) NOT NULL DEFAULT 'standard',  -- standard | strict
  created_at       DATETIME     DEFAULT GETDATE()
);

ALTER TABLE messages ADD CONSTRAINT fk_messages_group
  FOREIGN KEY (group_id) REFERENCES groups(id);

-- ── Group Members ──────────────────────────────────────────────────
CREATE TABLE group_members (
  group_id  UNIQUEIDENTIFIER NOT NULL REFERENCES groups(id),
  user_id   UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
  role      NVARCHAR(20)     NOT NULL DEFAULT 'member',       -- member | admin
  joined_at DATETIME         DEFAULT GETDATE(),
  PRIMARY KEY (group_id, user_id)
);

-- ── Blocked Users ──────────────────────────────────────────────────
CREATE TABLE blocked_users (
  blocker_id UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
  blocked_id UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
  created_at DATETIME         DEFAULT GETDATE(),
  PRIMARY KEY (blocker_id, blocked_id)
);

-- ── Audit Log (קבצים שנחסמו) ──────────────────────────────────────
CREATE TABLE audit_log (
  id         UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
  user_id    UNIQUEIDENTIFIER REFERENCES users(id),
  file_name  NVARCHAR(255),
  file_type  NVARCHAR(50),
  file_size  INT,
  reason     NVARCHAR(500),              -- סיבת החסימה מה-AI
  appealed   BIT NOT NULL DEFAULT 0,     -- האם הוגש ערעור
  created_at DATETIME DEFAULT GETDATE()
);

-- ── FCM Tokens (Push Notifications) ───────────────────────────────
CREATE TABLE fcm_tokens (
  user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
  token      NVARCHAR(500)    NOT NULL,
  device_id  NVARCHAR(255)    NOT NULL DEFAULT 'default',
  updated_at DATETIME         DEFAULT GETDATE(),
  PRIMARY KEY (user_id, device_id)
);
