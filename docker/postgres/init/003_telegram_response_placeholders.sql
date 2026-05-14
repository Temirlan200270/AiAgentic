CREATE TABLE IF NOT EXISTS telegram_response_placeholders (
    execution_id TEXT PRIMARY KEY,
    telegram_update_id BIGINT,
    chat_id BIGINT NOT NULL,
    placeholder_message_id BIGINT NOT NULL,
    route VARCHAR(40),
    status VARCHAR(40) NOT NULL DEFAULT 'sent',
    placeholder_text TEXT,
    final_text TEXT,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    final_sent_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_telegram_response_placeholders_chat_created
    ON telegram_response_placeholders(chat_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_telegram_response_placeholders_status_created
    ON telegram_response_placeholders(status, created_at DESC);
