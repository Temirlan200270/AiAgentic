# Database Schema: Personal AI Assistant

Database engine: PostgreSQL.
Deployment target for MVP: PostgreSQL in Docker, running together with local n8n in Docker.

All n8n PostgreSQL nodes and SQL queries must follow this schema.

## Design Notes

- `user_id` is the Telegram user ID.
- `chat_id` is the Telegram chat ID. It is stored where useful for outgoing Telegram messages and future multi-chat support.
- Timestamps use `TIMESTAMPTZ` so timezone handling stays sane.
- Default user timezone for reminder interpretation is `Asia/Qyzylorda`.
- `call_type` in `llm_usage_log` distinguishes **router**, **synthesizer**, **analysis_interpreter**, **research_interpreter**, and optional **task_planner** calls.
- Default currency for finance records is `KZT`.
- n8n should run locally in Docker for the MVP.
- n8n and PostgreSQL should share the same Docker Compose network.
- From inside the n8n container, use the PostgreSQL service name as host, for example `postgres`, not `localhost`.

## Docker PostgreSQL Baseline

Use these defaults unless the user changes them:

```text
POSTGRES_PORT=5432
POSTGRES_DB=personal_ai_assistant
POSTGRES_USER=assistant_user
POSTGRES_PASSWORD=<local secret>
```

For the MVP, prefer local n8n in Docker so PostgreSQL can stay local and private.

## DDL

```sql
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

CREATE INDEX IF NOT EXISTS idx_telegram_response_placeholders_chat_created
    ON telegram_response_placeholders(chat_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_telegram_response_placeholders_status_created
    ON telegram_response_placeholders(status, created_at DESC);

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

INSERT INTO telegram_poll_state (id, last_update_id)
VALUES (1, 0)
ON CONFLICT (id) DO NOTHING;
```

Docker init applies `001_assistant_schema.sql` then `002_user_profile.sql` on **first** volume creation. If your PostgreSQL volume already exists from before `user_profile`, run `002_user_profile.sql` once against the database (see `docker/postgres/init/002_user_profile.sql`).

## Common SQL Queries for n8n

### Load Recent Chat Messages

Use this query shape in the Load Memory PostgreSQL node. Keep a compact memory for the router and a richer one for the final reply.

```sql
SELECT
  COALESCE(
    (
      SELECT json_agg(row_to_json(m))
      FROM (
        SELECT role, LEFT(content, 500) AS content, created_at
        FROM (
          SELECT role, content, created_at
          FROM chat_memory
          WHERE user_id = $1
          ORDER BY created_at DESC
          LIMIT 4
        ) recent_router
        ORDER BY created_at ASC
      ) m
    ),
    '[]'::json
  ) AS router_memory,
  COALESCE(
    (
      SELECT json_agg(row_to_json(m))
      FROM (
        SELECT role, LEFT(content, 1200) AS content, created_at
        FROM (
          SELECT role, content, created_at
          FROM chat_memory
          WHERE user_id = $1
          ORDER BY created_at DESC
          LIMIT 6
        ) recent_synth
        ORDER BY created_at ASC
      ) m
    ),
    '[]'::json
  ) AS synth_memory;
```

Parameters:

1. `user_id`

### Save User Message

```sql
INSERT INTO chat_memory (user_id, chat_id, role, content, metadata)
VALUES ($1, $2, 'user', $3, $4::jsonb)
RETURNING id;
```

Parameters:

1. `user_id`
2. `chat_id`
3. `user_message`
4. metadata JSON, for example `{"message_id": 123}`

### Save Assistant Message

```sql
INSERT INTO chat_memory (user_id, chat_id, role, content, metadata)
VALUES ($1, $2, 'assistant', $3, $4::jsonb)
RETURNING id;
```

Parameters:

1. `user_id`
2. `chat_id`
3. assistant response text
4. metadata JSON, for example `{"route": "chat"}`

### Upsert user profile (search geography)

Optional per-Telegram-user defaults used by Load Memory and the Search Context Builder. If no row exists, SQL defaults **Pavlodar / Kazakhstan** apply in the Load Memory query.

```sql
INSERT INTO user_profile (user_id, default_city, default_country, location_mode, search_radius_km)
VALUES ($1, $2, $3, COALESCE($4, 'auto'), $5)
ON CONFLICT (user_id) DO UPDATE SET
  default_city = EXCLUDED.default_city,
  default_country = EXCLUDED.default_country,
  location_mode = EXCLUDED.location_mode,
  search_radius_km = EXCLUDED.search_radius_km,
  updated_at = NOW()
RETURNING *;
```

Parameters:

1. `user_id` (Telegram user id)
2. `default_city` (for example `Pavlodar`)
3. `default_country` (for example `Kazakhstan`)
4. `location_mode` (`auto`, `always_local`, or `always_global`) — optional
5. `search_radius_km` — optional integer or NULL

See also `scripts/seed-user-profile-pavlodar.ps1` (e.g. `-Mode Allowlist` or `-Mode FromMemory`) to bulk-create rows for Telegram IDs.

### Add Finance Transaction

```sql
INSERT INTO finance_log (
    user_id,
    chat_id,
    transaction_type,
    amount,
    currency,
    category,
    description,
    transaction_at,
    source_message_id
)
VALUES ($1, $2, $3, $4, COALESCE($5, 'KZT'), $6, $7, COALESCE($8, NOW()), $9)
RETURNING *;
```

Parameters:

1. `user_id`
2. `chat_id`
3. `transaction_type`
4. `amount`
5. `currency`
6. `category`
7. `description`
8. `transaction_at`
9. `message_id`

### Finance Summary by Category

```sql
SELECT
    category,
    transaction_type,
    currency,
    SUM(amount) AS total_amount,
    COUNT(*) AS transaction_count
FROM finance_log
WHERE user_id = $1
  AND transaction_at >= $2
  AND transaction_at < $3
GROUP BY category, transaction_type, currency
ORDER BY transaction_type, total_amount DESC;
```

Parameters:

1. `user_id`
2. period start timestamp
3. period end timestamp

### Recent Finance Transactions

```sql
SELECT transaction_type, amount, currency, category, description, transaction_at
FROM finance_log
WHERE user_id = $1
ORDER BY transaction_at DESC
LIMIT $2;
```

Parameters:

1. `user_id`
2. limit

### Add Reminder

```sql
INSERT INTO reminders (
    user_id,
    chat_id,
    task_text,
    remind_at,
    timezone,
    source_message_id
)
VALUES ($1, $2, $3, $4, COALESCE($5, 'Asia/Qyzylorda'), $6)
RETURNING *;
```

Parameters:

1. `user_id`
2. `chat_id`
3. `task_text`
4. `remind_at`
5. `timezone`
6. `message_id`

### Load Due Reminders for Future Reminder Workflow

This query is for a separate Cron-based workflow, not the main chat workflow.

```sql
SELECT id, user_id, chat_id, task_text, remind_at, timezone
FROM reminders
WHERE is_done = FALSE
  AND remind_at <= NOW()
ORDER BY remind_at ASC
LIMIT 50;
```

### Mark Reminder as Delivered

```sql
UPDATE reminders
SET is_done = TRUE,
    delivered_at = NOW()
WHERE id = $1
RETURNING *;
```

### Load Telegram Poll State

```sql
SELECT last_update_id
FROM telegram_poll_state
WHERE id = 1;
```

### Save Telegram Poll State

```sql
UPDATE telegram_poll_state
SET last_update_id = GREATEST(last_update_id, $1),
    updated_at = NOW()
WHERE id = 1
RETURNING *;
```

Parameters:

1. Telegram `update_id`

### Save LLM Usage

```sql
INSERT INTO llm_usage_log (
    user_id,
    chat_id,
    message_id,
    route,
    call_type,
    model,
    prompt_tokens,
    completion_tokens,
    total_tokens,
    raw_usage
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb)
RETURNING id;
```

Parameters:

1. `user_id`
2. `chat_id`
3. `message_id`
4. route name
5. call type, for example `router` or `synthesizer`
6. model name
7. prompt tokens
8. completion tokens
9. total tokens
10. raw usage JSON

### Register Processed Telegram Update

This is the business idempotency guard. It runs after poll state is saved and before allowlist or paid operations.

```sql
INSERT INTO processed_telegram_updates (
    telegram_update_id,
    execution_id,
    user_id,
    chat_id,
    message_id,
    input_kind
)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (telegram_update_id) DO NOTHING
RETURNING telegram_update_id;
```

If no row is returned, the update is a duplicate and should be skipped.

### Save Execution Log

```sql
INSERT INTO execution_log (
    execution_id,
    workflow_name,
    telegram_update_id,
    user_id,
    chat_id,
    message_id,
    route,
    input_kind,
    success,
    error,
    duration_ms,
    started_at,
    finished_at
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, NOW())
ON CONFLICT (execution_id) DO UPDATE SET
    route = EXCLUDED.route,
    success = EXCLUDED.success,
    error = EXCLUDED.error,
    duration_ms = EXCLUDED.duration_ms,
    finished_at = EXCLUDED.finished_at
RETURNING id;
```

### Save Tool Execution Log

```sql
INSERT INTO tool_execution_log (
    execution_id,
    telegram_update_id,
    tool_name,
    route,
    latency_ms,
    retry_count,
    success,
    error_type,
    error
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING id;
```

### Save Unsent Telegram Message

If Telegram send fails, store the generated response for later inspection or retry.

```sql
INSERT INTO unsent_telegram_messages (
    execution_id,
    telegram_update_id,
    chat_id,
    message_id,
    route,
    response_text,
    error
)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING id;
```

## Data Retention Policy

Observability and log tables grow indefinitely. For personal use, run cleanup manually or schedule a future Cron workflow.

Recommended retention periods:

| Table | Retention | Reason |
|-------|-----------|--------|
| `llm_usage_log` | 90 days | Cost analytics window |
| `execution_log` | 90 days | Debug and performance window |
| `tool_execution_log` | 90 days | Tool reliability analysis |
| `processed_telegram_updates` | 30 days | Idempotency guard; old entries are irrelevant |
| `chat_memory` | 180 days | Conversation context; summarize before deleting if needed |
| `unsent_telegram_messages` | 30 days | Inspect failures, then discard |

### Cleanup SQL

Run manually or add to a scheduled n8n workflow:

```sql
DELETE FROM llm_usage_log WHERE created_at < NOW() - INTERVAL '90 days';
DELETE FROM execution_log WHERE created_at < NOW() - INTERVAL '90 days';
DELETE FROM tool_execution_log WHERE created_at < NOW() - INTERVAL '90 days';
DELETE FROM processed_telegram_updates WHERE processed_at < NOW() - INTERVAL '30 days';
DELETE FROM unsent_telegram_messages WHERE created_at < NOW() - INTERVAL '30 days';
-- chat_memory: clean only if memory summarization is implemented
-- DELETE FROM chat_memory WHERE created_at < NOW() - INTERVAL '180 days';
```
