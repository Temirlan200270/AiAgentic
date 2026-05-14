-- Per-user defaults for search geography and related preferences.
-- Runs on fresh Docker volumes after 001_assistant_schema.sql.
-- Existing databases: apply this file once (see docs/database_schema.md).

CREATE TABLE IF NOT EXISTS user_profile (
    user_id BIGINT PRIMARY KEY,
    default_city VARCHAR(120) NOT NULL DEFAULT 'Pavlodar',
    default_country VARCHAR(120) NOT NULL DEFAULT 'Kazakhstan',
    location_mode VARCHAR(32) NOT NULL DEFAULT 'auto'
        CHECK (location_mode IN ('auto', 'always_local', 'always_global')),
    search_radius_km INTEGER CHECK (search_radius_km IS NULL OR search_radius_km > 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_profile_updated
    ON user_profile(updated_at DESC);
