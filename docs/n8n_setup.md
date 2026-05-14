# n8n Local Setup

## Start Runtime

Start local services:

```powershell
.\scripts\start-local.ps1
```

From classic `cmd.exe`:

```cmd
scripts\start-local.cmd
```

Open n8n:

```text
http://localhost:5678
```

Check PostgreSQL tables:

```powershell
.\scripts\check-db.ps1
```

From classic `cmd.exe`:

```cmd
scripts\check-db.cmd
```

To start, verify, sync, and activate the full local system in one step:

```powershell
.\deploy-local.cmd
```

The one-click deploy script is the preferred local path after `.env` and credentials are configured.

## Credentials

Create credentials in the n8n UI.

### PostgreSQL

Use:

```text
Host: postgres
Port: 5432
Database: personal_ai_assistant
User: assistant_user
Password: value from local .env
SSL: disabled for local Docker
```

Do not use `localhost` as PostgreSQL host from inside n8n.

After importing `Personal AI Assistant MVP`, open the workflow and assign this PostgreSQL credential to every Postgres node that shows missing credentials.

### Telegram

Use the bot token from BotFather.

Recommended storage:

- n8n Credentials in UI, or
- local `.env` only if a workflow/node explicitly reads it.

Do not paste Telegram token into committed files.

### OpenAI

Use the OpenAI API key in n8n Credentials.

Recommended model defaults:

```text
Router: gpt-5.4-mini
Synthesizer: gpt-5.4-mini
Transcription: gpt-4o-mini-transcribe
```

### Tavily

Use the Tavily API key for the HTTP Request node.

Recommended header:

```text
Authorization: Bearer <TAVILY_API_KEY>
```

Search endpoint:

```text
https://api.tavily.com/search
```

## Telegram Mode

Start with polling through Telegram Bot API `getUpdates`.

Polling entry in n8n:

```text
Schedule Trigger -> PostgreSQL Load Poll State -> HTTP Request getUpdates -> Normalize Updates -> Save Poll State Immediately -> Register Processed Update -> Gate Duplicate Updates -> Gate Allowed Users -> Switch Input Kind -> Main Assistant Flow
```

Use Telegram `offset = last_update_id + 1`.

The workflow saves `last_update_id` before voice download, transcription, OpenAI routing, Tavily, or database tools. This prevents a failed expensive step from replaying the same Telegram update forever.

After poll acknowledgement, the workflow writes `processed_telegram_updates`. A duplicate `telegram_update_id` is skipped before paid or stateful work.

Allowed users are controlled by:

```env
TELEGRAM_ALLOWED_USER_IDS=6018901784,126765781
```

Voice messages are supported through Telegram `getFile`, file download, and OpenAI transcription before entering the normal text path.

Telegram getUpdates endpoint:

```text
https://api.telegram.org/bot{{ TELEGRAM_BOT_TOKEN }}/getUpdates
```

If webhook mode is required later, expose local n8n with a public tunnel and set:

```env
WEBHOOK_URL=https://your-public-tunnel-url
```

Tunnel options:

- ngrok
- Cloudflare Tunnel
- another reverse proxy

## Imported Workflow

The MVP workflow is generated at:

```text
workflows/personal_assistant_mvp.json
```

Recommended deploy/sync path:

```powershell
.\deploy-local.cmd
```

Manual regenerate/import path, kept for troubleshooting:

```powershell
.\scripts\generate-mvp-workflow.ps1
$cid = docker compose ps -q n8n
docker cp workflows\personal_assistant_mvp.json ${cid}:/tmp/personal_assistant_mvp.json
docker compose exec -T n8n n8n import:workflow --input=/tmp/personal_assistant_mvp.json
```

Imported workflow name:

```text
Personal AI Assistant MVP
```

Keep it inactive until:

- PostgreSQL credentials are assigned to Postgres nodes.
- The workflow is opened and saved once in the n8n UI.
- A manual execution works without node configuration errors.

The current deployed workflow includes:

- early poll acknowledgement
- business idempotency with `processed_telegram_updates`
- early Telegram allowlist
- text and voice input branches
- Switch Route for deterministic routing
- normalized tool errors
- `llm_usage_log` persistence for token accounting
- `execution_log` and `tool_execution_log` for observability
- `unsent_telegram_messages` for Telegram send failures

## Reminder Delivery Workflow

A separate Cron-based workflow delivers due reminders:

```text
workflows/reminders_delivery_workflow.json
```

Workflow name in n8n:

```text
Reminder Delivery
```

Architecture:

```text
Cron (every 2 min) -> Load Due Reminders -> Filter & Prepare Messages
-> Send Telegram Reminder -> Process Send Result
-> Mark Reminder Delivered + Log Delivery Error
```

This workflow shares the same PostgreSQL credential as the main workflow. Assign it to all three Postgres nodes before activation.

If Telegram send fails, the generated message is saved to `unsent_telegram_messages` for inspection. Successfully delivered reminders are marked `is_done = TRUE`.

## Active Workflows

The local n8n instance should have exactly two active workflows:

| Workflow | Trigger | Role |
|----------|---------|------|
| Personal AI Assistant MVP | Schedule Trigger (polling every 10 sec) | Process Telegram messages |
| Reminder Delivery | Cron (every 2 min) | Deliver due reminders |

## Troubleshooting (empty canvas, `?new=true`, MCP)

If you keep landing on **My workflow N**, see nothing after import, or MCP does not mirror JSON automatically:

```text
docs/n8n_local_troubleshooting.md
```
