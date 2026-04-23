CREATE TABLE users (
  id            UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
  name          NVARCHAR(100)  NOT NULL,
  email         NVARCHAR(255)  NOT NULL UNIQUE,
  password_hash NVARCHAR(255)  NOT NULL,
  wins          INT            DEFAULT 0,
  games_played  INT            DEFAULT 0,
  created_at    DATETIME       DEFAULT GETDATE()
);

CREATE TABLE games (
  id          UNIQUEIDENTIFIER DEFAULT NEWID() PRIMARY KEY,
  player1_id  UNIQUEIDENTIFIER REFERENCES users(id),
  player2_id  UNIQUEIDENTIFIER REFERENCES users(id),
  winner_id   UNIQUEIDENTIFIER REFERENCES users(id),
  result      NVARCHAR(10)     CHECK (result IN ('win','tie')),
  board       NVARCHAR(50),
  played_at   DATETIME         DEFAULT GETDATE()
);

CREATE TABLE password_reset_tokens (
  token      NVARCHAR(64)     PRIMARY KEY,
  user_id    UNIQUEIDENTIFIER NOT NULL REFERENCES users(id),
  expires_at DATETIME         NOT NULL,
  used       BIT              DEFAULT 0
);
