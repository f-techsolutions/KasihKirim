import * as SQLite from 'expo-sqlite';

/** Local cache + outbox. WAL so writes survive process death mid-handover. */
export const db = SQLite.openDatabaseSync('kasihkirim.db');

export function initLocalDb() {
  db.execSync(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;

    CREATE TABLE IF NOT EXISTS outbox (
      id               TEXT PRIMARY KEY,
      created_at       INTEGER NOT NULL,
      endpoint         TEXT NOT NULL,
      method           TEXT NOT NULL,
      payload          TEXT NOT NULL,
      idempotency_key  TEXT NOT NULL UNIQUE,
      depends_on       TEXT REFERENCES outbox(id),
      entity_type      TEXT NOT NULL,
      entity_id        TEXT NOT NULL,
      attempts         INTEGER NOT NULL DEFAULT 0,
      next_attempt_at  INTEGER NOT NULL,
      status           TEXT NOT NULL DEFAULT 'PENDING',
      last_error       TEXT
    );
    CREATE INDEX IF NOT EXISTS ix_outbox_ready ON outbox(status, next_attempt_at);

    CREATE TABLE IF NOT EXISTS media_queue (
      id          TEXT PRIMARY KEY,
      local_uri   TEXT NOT NULL,
      bucket      TEXT NOT NULL,
      remote_path TEXT NOT NULL,
      bytes       INTEGER NOT NULL,
      outbox_id   TEXT,
      status      TEXT NOT NULL DEFAULT 'PENDING'
    );

    CREATE TABLE IF NOT EXISTS cache_entities (
      table_name TEXT NOT NULL,
      id         TEXT NOT NULL,
      data       TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      cached_at  INTEGER NOT NULL,
      PRIMARY KEY (table_name, id)
    );

    CREATE TABLE IF NOT EXISTS sync_cursors (
      table_name TEXT PRIMARY KEY,
      cursor     TEXT NOT NULL
    );
  `);
}
