# Personal AI Assistant

Pragmatic MVP of a personal AI assistant built around n8n, Telegram, PostgreSQL, Tavily, and ChatGPT-compatible OpenAI models.

The main idea is deliberately simple:

```text
Telegram Polling -> Save Poll State -> Allowlist -> Text/Voice Input -> Load Memory
-> AI Router -> Switch Route -> Tools -> AI Synthesizer or Direct Reply -> Telegram + Memory + Usage Log
```

No multi-agent complexity in the MVP. The assistant uses one LLM call for routing and one LLM call for the final answer on the normal path, with direct deterministic replies for simple confirmations.

## Current Decisions

- n8n runtime: local n8n in Docker
- Database: PostgreSQL in Docker
- Search provider: Tavily
- Telegram bot: created; token stored only in n8n Credentials or local `.env`
- LLM provider: OpenAI / ChatGPT-compatible model, configured through `.env`
- n8n image: pinned in `docker-compose.yml` instead of `latest`

## What This Repo Contains

```text
docs/
  architecture_mcp.md   Rules for generating the n8n workflow through Cursor + n8n-mcp
  database_schema.md    PostgreSQL schema and common SQL queries
  ai_prompts.md         Prompts for the AI Router and AI Synthesizer
  n8n_setup.md          Local n8n credentials and setup notes
  n8n_local_troubleshooting.md  Empty canvas, ?new=true, MCP vs JSON import
  smoke_tests.md        Telegram smoke-test checklist for routes and workflow behavior
  roadmap.md            MVP implementation roadmap
  task_planning_next.md Future task planning layer and guardrails
docker/
  postgres/init/        PostgreSQL init SQL for assistant tables (001 schema, 002 user_profile)
scripts/                Local helper scripts for Docker, DB checks, backup/restore
workflows/              MCP build prompt, workflow exports, and reminder specs
  telegram_polling_entry.md
  personal_assistant_mvp.json
  reminders_delivery_workflow.json
  reminders_delivery_workflow.md
docker-compose.yml      Local n8n + PostgreSQL runtime
.env.example            Safe example of required local variables
```

These files are the source of truth for Cursor and Codex when generating or updating the n8n workflow.

## Target Stack

- local n8n in Docker for workflow orchestration
- Telegram Bot API for chat input/output
- PostgreSQL in Docker for memory, finance logs, and reminders
- OpenAI / ChatGPT-compatible model for LLM calls
- Tavily for web search

## MVP Features

- Chat through Telegram
- Telegram text and voice input
- Telegram allowlist via `TELEGRAM_ALLOWED_USER_IDS`
- Short-term chat memory
- Finance logging and finance reports
- Web search branch for current information
- **Research** route: internet-based comparison, shortlist, recommendation, or ready-to-read report with sources.
- Reminder creation
- Final human-friendly response synthesis
- **Analysis** route: SQL aggregates from `finance_log` / `chat_memory`, optional Tavily for `analysis_type` `search` or `mixed`, then **Analysis Interpreter** LLM + Synthesizer (see `docs/architecture_mcp.md`).
- **Task plan** route: bounded JSON planning for non-trivial sequential requests, then Synthesizer explains the plan without entering agent loops.
- LLM token usage logging in PostgreSQL (`router`, `analysis_interpreter`, `research_interpreter`, `task_planner`, `synthesizer`)
- Graceful tool error normalization so the bot replies instead of silently failing
- Execution observability: request logs, tool logs, idempotency table, unsent Telegram response queue

## Recommended Cursor Command

Use this after connecting `n8n-mcp`:

```text
Read files in docs/. Create or adjust an n8n workflow for the personal AI assistant strictly following docs/architecture_mcp.md. Use PostgreSQL according to docs/database_schema.md and prompts from docs/ai_prompts.md. Use Tavily for search/research. Do not add multi-agents; the only extra LLM nodes beyond router+synthesizer are the documented Analysis Interpreter, Research Planner, Research Interpreter, and bounded Task Planner routes.
```

## Environment Variables

Do not commit real secrets. Keep them in local n8n Credentials or a local `.env` file ignored by Git.

> **N8N_ENCRYPTION_KEY - Critical**
>
> If `N8N_ENCRYPTION_KEY` is empty or missing in `.env`, n8n generates a random key on first boot and stores it inside the Docker volume. Running `docker compose down -v` **destroys that key**, making all saved Credentials (Telegram, OpenAI, PostgreSQL) unreadable. You will have to re-enter every credential.
>
> **Always set a stable key before first boot:**
>
> ```powershell
> .\scripts\generate-n8n-encryption-key.ps1
> ```
>
> Copy the output into `.env` as `N8N_ENCRYPTION_KEY=<generated value>` and never change it.

Expected variables if environment-based configuration is used:

```text
N8N_PORT=5678
N8N_HOST=localhost
N8N_PROTOCOL=http
N8N_EDITOR_BASE_URL=http://localhost:5678
N8N_SECURE_COOKIE=false
WEBHOOK_URL=
N8N_ENCRYPTION_KEY=
OPENAI_API_KEY=
TELEGRAM_BOT_TOKEN=
TELEGRAM_ALLOWED_USER_IDS=
POSTGRES_HOST=
POSTGRES_PORT=5432
POSTGRES_DB=personal_ai_assistant
POSTGRES_USER=assistant_user
POSTGRES_PASSWORD=
SEARCH_PROVIDER=tavily
SEARCH_API_KEY=
TAVILY_API_KEY=
DEFAULT_USER_CITY=Pavlodar
DEFAULT_USER_COUNTRY=Kazakhstan
OPENAI_ROUTER_MODEL=gpt-5.4-mini
OPENAI_ANALYSIS_MODEL=gpt-5.4-mini
OPENAI_SYNTHESIZER_MODEL=gpt-5.4-mini
OPENAI_TRANSCRIBE_MODEL=gpt-4o-mini-transcribe
```

## Database

PostgreSQL is the preferred database from the start. For the MVP it is expected to run in Docker.

Decision: use local n8n in Docker together with PostgreSQL in Docker. This avoids the n8n Cloud -> local database connection problem.

Important Docker rule: if n8n and PostgreSQL run as containers in the same Docker Compose network, n8n must connect to PostgreSQL using the service name, for example `postgres`, not `localhost`.

If Telegram webhooks are used with local n8n, expose n8n through a tunnel such as ngrok or Cloudflare Tunnel. For simpler local testing, use Telegram polling if available.

Create tables using the DDL in:

```text
docs/database_schema.md
```

Smoke-test checklist:

```text
docs/smoke_tests.md
```

The same schema is also available as Docker init scripts:

```text
docker/postgres/init/001_assistant_schema.sql
docker/postgres/init/002_user_profile.sql
docker/postgres/init/003_telegram_response_placeholders.sql
```

If your PostgreSQL volume was created **before** `user_profile` existed, apply `002` once while Postgres is running:

```powershell
.\scripts\apply-user-profile-migration.ps1
```

If your PostgreSQL volume was created **before** placeholder UX support existed, apply `003` once while Postgres is running:

```powershell
.\scripts\apply-placeholder-migration.ps1
```

To attach **existing Telegram user IDs** to Pavlodar for local search (writes rows in `user_profile`):

```powershell
# IDs from TELEGRAM_ALLOWED_USER_IDS in .env
.\scripts\seed-user-profile-pavlodar.ps1 -Mode Allowlist

# Or all user_id values already present in chat_memory
.\scripts\seed-user-profile-pavlodar.ps1 -Mode FromMemory
```

Reliability/observability tables:

- `processed_telegram_updates`: business idempotency by `telegram_update_id`.
- `execution_log`: route, input kind, success/error, duration, started/finished timestamps.
- `tool_execution_log`: tool name, latency, retry count, success/error.
- `llm_usage_log`: token usage for router, synthesizer, analysis, research, and task planning calls.
- `unsent_telegram_messages`: generated responses that Telegram did not accept.

## Local Docker Runtime

Start local n8n and PostgreSQL:

```powershell
.\scripts\start-local.ps1
```

From classic `cmd.exe`, use:

```cmd
scripts\start-local.cmd
```

Open n8n:

```text
http://localhost:5678
```

Stop services:

```powershell
.\scripts\stop-local.ps1
```

Stop services and remove local database/n8n volumes:

```powershell
docker compose down -v
```

Only use `down -v` when you intentionally want to delete local n8n data, credentials, workflows, and PostgreSQL data.

Check database schema:

```powershell
.\scripts\check-db.ps1
```

From classic `cmd.exe`, use:

```cmd
scripts\check-db.cmd
```

Watch logs:

```powershell
.\scripts\logs.ps1
.\scripts\logs.ps1 n8n
.\scripts\logs.ps1 postgres
```

From classic `cmd.exe`:

```cmd
scripts\logs.cmd
scripts\logs.cmd n8n
scripts\logs.cmd postgres
```

Check external integrations without printing secrets:

```powershell
.\scripts\test-integrations.ps1
```

From classic `cmd.exe`:

```cmd
scripts\test-integrations.cmd
```

Deploy the full local system in one step:

```powershell
.\deploy-local.cmd
```

This starts Docker services, checks PostgreSQL, verifies external integrations, syncs `workflows/personal_assistant_mvp.json` into n8n, and activates `Personal AI Assistant MVP`.

Create a local PostgreSQL backup:

```powershell
.\scripts\backup-db.ps1
```

Restore a local PostgreSQL backup:

```powershell
.\scripts\restore-db.ps1 .\backups\personal_ai_assistant-YYYYMMDD-HHMMSS.sql
```

## Telegram Mode

MVP starts with explicit Telegram polling through Bot API `getUpdates`.

Use this entry pattern:

```text
Schedule Trigger -> Load Poll State -> Telegram getUpdates -> Normalize Updates
-> Save Poll State Immediately -> Idempotency Check -> Gate Allowed Users -> Switch Input Kind
-> Text or Voice Processing -> Main Assistant Flow
```

Details:

```text
workflows/telegram_polling_entry.md
```

For webhook mode later, set:

```env
WEBHOOK_URL=https://your-public-tunnel-url
```

Local webhook options:

- ngrok
- Cloudflare Tunnel
- another public reverse proxy

## Workflow Build

After n8n is running and credentials are configured, build the main workflow with `n8n-mcp` using:

```text
workflows/build_with_mcp.md
```

The current importable MVP workflow is:

```text
Personal AI Assistant MVP
```

Source file:

```text
workflows/personal_assistant_mvp.json
```

Recommended local deploy:

```powershell
.\deploy-local.cmd
```

Manual regenerate/import is kept for troubleshooting only:

```powershell
.\scripts\generate-mvp-workflow.ps1
$cid = docker compose ps -q n8n
docker cp workflows\personal_assistant_mvp.json ${cid}:/tmp/personal_assistant_mvp.json
docker compose exec -T n8n n8n import:workflow --input=/tmp/personal_assistant_mvp.json
```

Before activation, ensure the local PostgreSQL credential is assigned to all Postgres nodes.

### Sync graph + SQL from the repo (REST API)

If the workflow opens with **no connections** or broken nodes, sync from `workflows/personal_assistant_mvp.json` while keeping **server node IDs and Postgres credentials**:

1. In n8n: **Settings -> API** - create an API key.
2. In the project `.env` add: `N8N_API_KEY=<your key>` (this file is gitignored).
3. From the repo root:

```powershell
python .\scripts\sync-mvp-workflow.py
```

Optional: `N8N_BASE_URL`, `WORKFLOW_ID` in `.env` if not using defaults (`http://127.0.0.1:5678` and your workflow id).

### Create workflow via API (when UI import shows nothing)

If **Import from File** leaves a blank canvas and no error:

```powershell
python .\scripts\create-mvp-workflow-api.py
```

The script prints the HTTP status/body and saves `logs/n8n-create-workflow-*.log`. Alternatively, CLI import with logging:

```powershell
.\scripts\import-mvp-docker-cli.ps1
```

## Task Planning Layer

Task planning is intentionally bounded and planning-only in the main MVP workflow.

Current route:

```text
route = task_plan
```

The planner is an optional tool. A separate Cron-based Task Runner should execute one atomic step per run when async task execution is added.

Guardrails and future schema notes are in:

```text
docs/task_planning_next.md
```

Reminder delivery is built from:

```text
workflows/reminders_delivery_workflow.md
```

## Reminder Delivery Workflow

The main workflow creates reminders. A second workflow delivers them:

```text
Cron (every 2 min) -> Load Due Reminders -> Filter & Prepare Messages -> Send Telegram -> Mark Done / Log Error
```

Source file:

```text
workflows/reminders_delivery_workflow.json
```

Import into n8n the same way as the main workflow. Assign the PostgreSQL credential to both Postgres nodes before activation.

The workflow sends overdue reminders via Telegram, marks successful deliveries as `is_done = TRUE`, and logs failed sends to `unsent_telegram_messages`.

## Troubleshooting

### n8n: new empty workflow every time, or blank Editor after import

See:

```text
docs/n8n_local_troubleshooting.md
```

Typical fixes: remove `?new=true` from the URL, open **Personal AI Assistant MVP** from **Workflows**, use the **Editor** tab (not **Executions**), assign Postgres credentials, run `python .\scripts\sync-mvp-workflow.py` if connections are missing. If import appears to do nothing, use `python .\scripts\create-mvp-workflow-api.py` or `.\scripts\import-mvp-docker-cli.ps1` - both write logs under `logs/` (see `docs/n8n_local_troubleshooting.md`).

### Docker daemon is not running

If `docker compose up -d` fails with an error about Docker API or `dockerDesktopLinuxEngine`, start Docker Desktop and try again:

```powershell
.\scripts\start-local.ps1
```

If you are in `cmd.exe`, run:

```cmd
scripts\start-local.cmd
```

### PostgreSQL tables are missing

Check the database:

```powershell
.\scripts\check-db.ps1
```

The init SQL runs only when the PostgreSQL volume is first created. If you intentionally want a clean local database, run:

```powershell
docker compose down -v
.\scripts\start-local.ps1
```

This deletes local n8n and PostgreSQL data.

### n8n cannot connect to PostgreSQL

Inside n8n credentials, use:

```text
Host: postgres
Port: 5432
Database: personal_ai_assistant
User: assistant_user
```

Do not use `localhost` as PostgreSQL host inside the n8n container.

### Telegram does not trigger locally

For local MVP, use the polling entry from:

```text
workflows/telegram_polling_entry.md
```

Webhook mode needs a public HTTPS URL and is intentionally deferred.

### Browser shows "Error connecting to n8n"

Check that n8n is reachable:

```powershell
Invoke-WebRequest http://localhost:5678/healthz -UseBasicParsing
```

For local HTTP, `.env` should include:

```env
N8N_EDITOR_BASE_URL=http://localhost:5678
N8N_SECURE_COOKIE=false
```

Then restart n8n:

```powershell
docker compose up -d --force-recreate n8n
```

If it still happens, open `http://localhost:5678` in an incognito/private window or clear site data for `localhost:5678`.

If the browser shows this JSON:

```json
{"code":503,"message":"Database is not ready!"}
```

n8n is running, but its backend has not finished initializing the database connection yet, or it briefly lost the connection. Wait 30-60 seconds and refresh. Check readiness:

```powershell
docker compose ps
Invoke-WebRequest http://localhost:5678/healthz -UseBasicParsing
```

If `/healthz` does not return OK and the browser console shows **`Database is not ready!`**, also check n8n logs for **`Database connection timed out`** or **`getaddrinfo EAI_AGAIN postgres`**. Restart both services on the same Compose network:

```powershell
docker compose restart postgres
docker compose restart n8n
```

### Workflow import breaks the UI (white screen) or Postgres logs show `null value in column "id"`

n8n stores workflow IDs as **UUIDs**. An export must not contain a string id like `"id": "personal-ai-assistant-mvp"` - that can make inserts into `workflow_entity` fail and leave the editor unstable.

The repo export `workflows/personal_assistant_mvp.json` is kept **without** a top-level `"id"` so n8n assigns a new UUID on import. If you still have a broken duplicate workflow in the UI, delete it and import this file again, then re-bind Postgres credentials.

### `/healthz` is still not OK after restarts

An **active** workflow that fails to activate on every startup can spam the DB and keep n8n in a bad state. Turn off all workflows in Postgres, then restart n8n:

```powershell
.\scripts\n8n-deactivate-all-workflows.ps1
docker compose restart n8n
```

Wait **1-2 minutes** until `docker compose ps` shows **n8n (healthy)**, then:

```powershell
Invoke-WebRequest http://localhost:5678/healthz -UseBasicParsing
```

### Reading n8n logs: `Database connection timed out` and `the database system is shutting down`

Those lines often appear together when **PostgreSQL was restarting** (for example after `docker compose restart postgres`, Docker Desktop resume, or sleep). n8n keeps retrying and usually prints **`Editor is now accessible`** once Postgres is up again.

To reduce spurious timeouts, this repo sets **`DB_POSTGRESDB_CONNECTION_TIMEOUT=60000`** (ms) in `docker-compose.yml`. Recreate n8n after editing compose:

```powershell
docker compose up -d --force-recreate n8n
```

## Model Choice

The exact ChatGPT model can be changed later.

Current MVP default:

- Router: `gpt-5.4-mini`
- Synthesizer: `gpt-5.4-mini`

The current OpenAI project did not have access to `gpt-4o-mini`, so the local `.env` uses the available `gpt-5.4-mini` model.

## MCP and Workflow Management

### Registered MCP Servers

```powershell
codex mcp list
docker mcp tools ls --format list
```

| Server | Type | Purpose | Status |
|--------|------|---------|--------|
| `n8n-mcp` (Codex) | Remote (api.n8n-mcp.com) | n8n workflow tools via OAuth | Blocked by SSRF |
| `n8n-mcp` (Antigravity) | Local Node.js (stdio) | Direct n8n API via localhost | Blocked by SSRF |
| `MCP_DOCKER` | Docker gateway | Browser automation (29 Playwright tools) | Works |

### SSRF Limitation

Both n8n MCP servers (Codex and Antigravity) are blocked by platform SSRF protection when targeting `localhost:5678`. This is a platform security restriction, not a configuration error.

### Working Approach: REST API

All workflow management (create, update, activate, delete) works reliably through the n8n REST API using the `N8N_API_KEY` from `.env`:

```powershell
# Sync main workflow from repo
python .\scripts\sync-mvp-workflow.py

# One-click full deploy
.\deploy-local.cmd
```

Docker MCP provides browser automation tools (Playwright) and is useful for interacting with the n8n UI when needed.

## Repository Rules

- Commit docs and workflow definitions.
- Do not commit `.env`, `.cursor/mcp.json`, n8n local data, database files, logs, or exported secrets.
- Keep the architecture tool-based until there is a real reason to expand it.
