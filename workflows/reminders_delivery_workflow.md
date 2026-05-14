# Reminder Delivery Workflow

Create this as a second n8n workflow after the main chat workflow is working.

## Architecture

```text
Cron -> Load Due Reminders -> Telegram Send -> Mark Reminder Done
```

## Cron

Run every minute or every 5 minutes for MVP.

## Load Due Reminders

Use PostgreSQL:

```sql
SELECT id, user_id, chat_id, task_text, remind_at, timezone
FROM reminders
WHERE is_done = FALSE
  AND remind_at <= NOW()
ORDER BY remind_at ASC
LIMIT 50;
```

## Telegram Send

Send to `chat_id`.

Suggested text:

```text
Напоминание: {{ $json.task_text }}
```

## Mark Reminder Done

Use PostgreSQL:

```sql
UPDATE reminders
SET is_done = TRUE,
    delivered_at = NOW()
WHERE id = $1
RETURNING *;
```

