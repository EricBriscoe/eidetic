-- Single-user by design: there is no users table. The app authenticates with
-- the APP_TOKEN secret; assistants authenticate via OAuth grants approved with
-- a short-lived code minted by the app.

CREATE TABLE sets (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT,
  -- Max never-seen cards introduced per local day.
  new_per_day INTEGER NOT NULL DEFAULT 20,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Content columns (front/back/position) are written by MCP; scheduling columns
-- (state..introduced_at) only by review sync from the app, which runs FSRS
-- on-device. MCP may reset scheduling to 'new' but never computes it.
CREATE TABLE cards (
  id            TEXT PRIMARY KEY,
  set_id        TEXT NOT NULL REFERENCES sets(id) ON DELETE CASCADE,
  front         TEXT NOT NULL,
  back          TEXT NOT NULL,
  position      INTEGER NOT NULL,
  state         TEXT NOT NULL DEFAULT 'new' CHECK (state IN ('new', 'learning', 'review', 'relearning')),
  step          INTEGER,
  stability     REAL,
  difficulty    REAL,
  due           TEXT,
  last_review   TEXT,
  reps          INTEGER NOT NULL DEFAULT 0,
  lapses        INTEGER NOT NULL DEFAULT 0,
  introduced_at TEXT,
  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX cards_set ON cards(set_id, position);

-- Append-only review log. id is a client UUID so outbox replays are idempotent.
CREATE TABLE reviews (
  id          TEXT PRIMARY KEY,
  card_id     TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  rating      INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 4),
  reviewed_at TEXT NOT NULL,
  duration_ms INTEGER,
  -- Card state when shown (retention = pass rate where prior_state = 'review'),
  -- then the scheduling it left with.
  prior_state TEXT NOT NULL,
  state       TEXT NOT NULL,
  stability   REAL,
  difficulty  REAL,
  due         TEXT
);
CREATE INDEX reviews_card ON reviews(card_id, reviewed_at);

-- Short-lived codes the app mints (POST /api/connect-code) and the user types
-- into the OAuth authorize page. D1, not KV: the code must be readable the
-- instant it is written, from whichever colo the browser lands on.
CREATE TABLE connect_codes (
  code_hash  TEXT PRIMARY KEY,
  expires_at TEXT NOT NULL
);

-- Failed code entries, for a global hourly cap on guessing.
CREATE TABLE connect_failures (
  at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
