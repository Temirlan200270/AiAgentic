# MVP Roadmap

## Stage 1: Local Runtime

- Start Docker Desktop.
- Run `.\scripts\start-local.ps1`, or `scripts\start-local.cmd` from classic `cmd.exe`.
- Open `http://localhost:5678`.
- Run `.\scripts\check-db.ps1`.

Preferred full local deploy:

```powershell
.\deploy-local.cmd
```

This starts services, checks integrations, syncs the workflow, and activates it.

## Stage 2: Credentials

Create or configure:

- PostgreSQL credential in n8n.
- Telegram bot token in `.env`.
- OpenAI API key in `.env`.
- Tavily API key in `.env`.
- `TELEGRAM_ALLOWED_USER_IDS` in `.env`.

Keep secrets in n8n Credentials or local `.env`. Never commit real tokens.

## Stage 3: Main Workflow

The current MVP workflow lives at:

```text
workflows/personal_assistant_mvp.json
```

It is deployed into local n8n as:

```text
Personal AI Assistant MVP
```

Current architecture:

```text
Telegram Polling -> Save Poll State Immediately -> Idempotency Check -> Allowlist -> Switch Input Kind
-> Text/Voice Processing -> Load Memory -> AI Router -> Switch Route
-> Tool Branches -> AI Synthesizer -> Telegram + Memory + Usage Log
```

Implemented routes:

- chat
- finance_add
- finance_report
- search
- research
- analysis
- reminder_add
- task_plan

Implemented reliability layers:

- early poll acknowledgement
- business idempotency with `processed_telegram_updates`
- early allowlist before paid operations
- deterministic Switch Route
- normalized tool errors
- parameterized SQL for key database operations
- n8n image pinning
- `llm_usage_log` token usage persistence
- `execution_log` for route/input/success/error/duration
- `tool_execution_log` for tool latency/success/error
- `unsent_telegram_messages` for Telegram send failures

## Stage 4: Manual Tests

Full checklist:

```text
docs/smoke_tests.md
```

Test these Telegram messages:

```text
привет, кто ты?
потратил 1500 на такси
сколько я потратил за неделю?
найди последние новости про OpenAI
найди 5 лучших кофеен рядом, сравни по рейтингу, отзывам и расстоянию, и выдай итог в формате таблицы и краткой рекомендации
проанализируй мои расходы за месяц и скажи, где можно сократить
напомни завтра в 9 позвонить врачу
```

Also test:

- a voice message with a normal chat question
- a voice message with a finance expense
- a voice message with a reminder
- a message from a Telegram user ID that is not in the allowlist
## Stage 5: Reminder Delivery

The main workflow creates reminders. Delivery is handled by a separate workflow:

```text
workflows/reminders_delivery_workflow.json
```

Spec:

```text
workflows/reminders_delivery_workflow.md
```

Deploy steps:

1. Import `workflows/reminders_delivery_workflow.json` into n8n.
2. Assign the PostgreSQL credential to both Postgres nodes.
3. Test: send the bot "напомни через 2 минуты выпить воду" and verify delivery.
4. Activate the workflow.

## Stage 6: Hardening

Completed:

- early poll state save
- early allowlist
- Switch-based route dispatch
- normalized tool error shape
- n8n image pinning
- usage logging table
- execution observability tables
- business idempotency guard
- unsent Telegram response logging
- memory window policy: short route-specific windows with trimmed content
- reminder delivery workflow (deployed and active)
- data retention policy documented with cleanup SQL

Recommended next hardening:

- add cost/budget report command from `llm_usage_log`
- add log cleanup Cron workflow (automated retention)
- add more execution/error dashboards
- add stricter tests for voice and finance extraction
- backup DB before major workflow edits with `.\scripts\backup-db.ps1`

## Stage 7: Task Planning Layer

Add this only after the MVP routes work reliably.

Reference:

```text
docs/task_planning_next.md
```

Target shape:

```text
Workflow 1: Chat Intake with optional task_plan route
Workflow 2: Cron Task Runner that executes one atomic step and exits
```

## Stage 8: Product Roadmap

The project should keep its current pragmatic core:

```text
Router LLM -> deterministic tools -> Direct Reply or Synthesizer LLM
```

This keeps cost, latency, and failure modes controllable. More agentic behavior should be added as separate routes or separate workflows, not by turning the main chat path into an open-ended loop.

### Quick Wins

- Vision input for photos and receipts.
  Add an image branch for Telegram photos/documents. For receipts, extract amount, date, merchant, and category, then route into `finance_add` with a confirmation step when confidence is low.
- Strict finance categories.
  Add a database-backed category dictionary and make the router map expenses only to known categories. This keeps reports cleaner than free-form LLM categories.
- Telegram-friendly research output.
  Keep research answers in compact text blocks instead of markdown tables: goal, top items, comparison, conclusion, recommendation, sources.
- Better waiting UX.
  Use Telegram placeholder messages for `search`, `research`, `analysis`, and `task_plan`, then edit them into the final answer with `editMessageText`. `sendChatAction` can still be added later as a lightweight extra.

### Core Features

- Async Task Executor.
  Add a separate Task Runner workflow that executes one atomic task step per run, records progress in PostgreSQL, and sends the final result when done. This is the right path for non-trivial sequential work.
- Long-term memory.
  Add weekly or daily summarization of older chat history into a structured user profile. Feed only the compact profile into Router/Synthesizer.
- Proactive notifications.
  Add scheduled morning briefings: weather, reminders, finance snapshot, and useful local context based on `user_profile`.
- Memory search route.
  Add `memory_search` after pgvector is available. This should be archival search, not a replacement for short-term chat memory.

### Architecture And DevOps

- Move from polling to webhook when hosting/tunnel is stable.
  Polling is acceptable for the local MVP, but webhook will remove the 1-10 second capture delay.
- Add database migrations.
  `docker/postgres/init` is good for clean startup, but schema changes should eventually move to a lightweight migration tool such as dbmate or Flyway.
- Add pgvector.
  Store embeddings for important messages, notes, and documents in PostgreSQL. Use it for semantic retrieval only where exact SQL is not appropriate.
- Keep generated exports out of source control.
  Large local artifacts such as `exports/nodes.json` should stay ignored and should not be used as source-of-truth documentation.

### Discussion Notes

- Vision gives the most visible user-facing upgrade.
- Task Executor gives the biggest capability upgrade, but also adds the most operational complexity.
- Webhook improves responsiveness, but should wait until the external URL story is stable.
- pgvector/RAG is useful for long-term memory and documents, not for finance totals, reminders, or exact analytics.
