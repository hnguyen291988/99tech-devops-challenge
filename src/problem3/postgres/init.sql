-- Runs once, on first initialisation of an empty data directory, because
-- docker-compose.yml now mounts this file into /docker-entrypoint-initdb.d/.
-- It previously was not mounted at all, so nothing in it ever executed.
--
-- The original contents were:
--     ALTER SYSTEM SET max_connections = 20;
-- which would not have taken effect even if the file had been mounted:
-- max_connections requires a server restart, and the value also has to agree
-- with the client pool size. It is now set as a server flag in
-- docker-compose.yml, where it applies at boot and sits next to the
-- DB_POOL_MAX it has to be consistent with.

BEGIN;

CREATE SCHEMA IF NOT EXISTS app;

CREATE TABLE IF NOT EXISTS app.users (
    id         BIGSERIAL PRIMARY KEY,
    email      TEXT        NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The endpoint is called /api/users, so let it actually read users. The
-- original handler ran SELECT NOW(), which meant it could return 200 while the
-- application schema was missing entirely.
INSERT INTO app.users (email) VALUES
    ('ada@example.com'),
    ('grace@example.com'),
    ('alan@example.com')
ON CONFLICT (email) DO NOTHING;

COMMIT;
