CREATE TABLE IF NOT EXISTS chat_memory (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    chat_id BIGINT,
    role VARCHAR(20) NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content TEXT NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS finance_log (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    chat_id BIGINT,
    transaction_type VARCHAR(20) NOT NULL CHECK (transaction_type IN ('income', 'expense')),
    amount NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
    currency VARCHAR(10) NOT NULL DEFAULT 'KZT',
    category VARCHAR(80),
    description TEXT,
    transaction_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    source_message_id BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS reminders (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    chat_id BIGINT NOT NULL,
    task_text TEXT NOT NULL,
    remind_at TIMESTAMPTZ NOT NULL,
    timezone VARCHAR(64) NOT NULL DEFAULT 'Asia/Qyzylorda',
    is_done BOOLEAN NOT NULL DEFAULT FALSE,
    delivered_at TIMESTAMPTZ,
    source_message_id BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS telegram_poll_state (
    id SMALLINT PRIMARY KEY DEFAULT 1,
    last_update_id BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT telegram_poll_state_singleton CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS llm_usage_log (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT,
    chat_id BIGINT,
    message_id BIGINT,
    route VARCHAR(40),
    call_type VARCHAR(40) NOT NULL,
    model VARCHAR(120),
    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    raw_usage JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS processed_telegram_updates (
    telegram_update_id BIGINT PRIMARY KEY,
    execution_id TEXT NOT NULL,
    user_id BIGINT,
    chat_id BIGINT,
    message_id BIGINT,
    input_kind VARCHAR(40),
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS execution_log (
    id BIGSERIAL PRIMARY KEY,
    execution_id TEXT NOT NULL UNIQUE,
    workflow_name TEXT NOT NULL,
    telegram_update_id BIGINT,
    user_id BIGINT,
    chat_id BIGINT,
    message_id BIGINT,
    route VARCHAR(40),
    input_kind VARCHAR(40),
    success BOOLEAN NOT NULL DEFAULT FALSE,
    error TEXT,
    duration_ms INTEGER,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tool_execution_log (
    id BIGSERIAL PRIMARY KEY,
    execution_id TEXT,
    telegram_update_id BIGINT,
    tool_name VARCHAR(80) NOT NULL,
    route VARCHAR(40),
    latency_ms INTEGER,
    retry_count INTEGER NOT NULL DEFAULT 0,
    success BOOLEAN NOT NULL DEFAULT FALSE,
    error_type VARCHAR(120),
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS unsent_telegram_messages (
    id BIGSERIAL PRIMARY KEY,
    execution_id TEXT,
    telegram_update_id BIGINT,
    chat_id BIGINT NOT NULL,
    message_id BIGINT,
    route VARCHAR(40),
    response_text TEXT NOT NULL,
    error TEXT,
    retry_count INTEGER NOT NULL DEFAULT 0,
    last_retry_at TIMESTAMPTZ,
    sent_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_chat_memory_user_created
    ON chat_memory(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_finance_log_user_transaction_at
    ON finance_log(user_id, transaction_at DESC);

CREATE INDEX IF NOT EXISTS idx_finance_log_user_type_transaction_at
    ON finance_log(user_id, transaction_type, transaction_at DESC);

CREATE INDEX IF NOT EXISTS idx_reminders_due
    ON reminders(is_done, remind_at);

CREATE INDEX IF NOT EXISTS idx_reminders_user
    ON reminders(user_id, is_done, remind_at);

CREATE INDEX IF NOT EXISTS idx_llm_usage_user_created
    ON llm_usage_log(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_llm_usage_created
    ON llm_usage_log(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_processed_telegram_updates_processed_at
    ON processed_telegram_updates(processed_at DESC);

CREATE INDEX IF NOT EXISTS idx_execution_log_created
    ON execution_log(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_execution_log_route_created
    ON execution_log(route, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_tool_execution_log_tool_created
    ON tool_execution_log(tool_name, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_unsent_telegram_messages_pending
    ON unsent_telegram_messages(sent_at, created_at DESC)
    WHERE sent_at IS NULL;

INSERT INTO telegram_poll_state (id, last_update_id)
VALUES (1, 0)
ON CONFLICT (id) DO NOTHING;
