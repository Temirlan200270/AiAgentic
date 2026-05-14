# Telegram Polling Entry Workflow

Use this entry pattern for local MVP instead of Telegram Trigger / webhook mode.

## Why

Local n8n at `http://localhost:5678` does not have a public HTTPS URL. Telegram webhooks need a public HTTPS URL, so polling is simpler for local development.

## Flow

```text
Schedule Trigger
-> PostgreSQL: Load Telegram Poll State
-> HTTP Request: Telegram getUpdates
-> Normalize Telegram Updates
-> PostgreSQL: Save Telegram Poll State immediately
-> PostgreSQL: Register Processed Update
-> Gate Duplicate Updates
-> Gate Allowed Users
-> Switch Input Kind
-> Text path or Voice transcription path
-> Continue to Main Assistant Flow
```

## Load Poll State

```sql
SELECT last_update_id
FROM telegram_poll_state
WHERE id = 1;
```

## getUpdates Request

Method:

```text
GET
```

URL:

```text
https://api.telegram.org/bot{{ TELEGRAM_BOT_TOKEN }}/getUpdates
```

Query parameters:

```text
offset={{ last_update_id + 1 }}
timeout=0
allowed_updates=["message"]
```

## Filter

Keep updates where `update.message` exists. Normalize these message kinds:

```text
text
voice
unsupported
```

Do not drop voice or unsupported messages before saving poll state. Dropping before acknowledgement can cause repeated retries.

## Normalize

Output fields:

```json
{
  "telegram_update_id": 123456,
  "user_id": 123,
  "chat_id": 123,
  "message_id": 10,
  "user_message": "text",
  "message_kind": "text",
  "voice_file_id": "",
  "input_error": "",
  "is_allowed": true,
  "received_at": "2026-05-09T12:00:00+05:00"
}
```

## Save Poll State

```sql
UPDATE telegram_poll_state
SET last_update_id = GREATEST(last_update_id, $1),
    updated_at = NOW()
WHERE id = 1
RETURNING *;
```

Parameter:

```text
telegram_update_id
```

## Register Processed Update

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

If the insert returns no row, skip the update.

## Gate Allowed Users

After saving poll state, filter by:

```text
TELEGRAM_ALLOWED_USER_IDS
```

This gate must run before Telegram voice download, OpenAI transcription, Tavily, and other paid or expensive operations.

## Voice Path

For `message_kind = voice`:

```text
Telegram getFile -> Download Telegram Voice -> Prepare OGG file -> OpenAI Transcribe Voice -> Normalize Voice Transcription
```

The output must return to the same shape as text input, with `user_message` set to the transcribed text.

If transcription fails, preserve the original update metadata and set `transcription_error`. The main flow should still answer gracefully.
