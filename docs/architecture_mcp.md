# n8n System Architecture: Personal AI Assistant

## Project Goal

Build a pragmatic MVP personal AI assistant in n8n.

Runtime channel: Telegram.  
Database: PostgreSQL in Docker.  
LLM provider: OpenAI / ChatGPT-compatible models.  
Search provider: Tavily.  
n8n runtime: local n8n in Docker.  
Telegram mode for MVP: polling through Telegram Bot API `getUpdates`.

The workflow should stay cheap, predictable, and easy to debug.

## Core Paradigm

Primary path:

```text
Telegram Polling Entry -> Save Poll State Immediately -> Idempotency Check -> Gate Allowed Users
-> Switch Input Kind -> Text/Voice Processing -> Load Memory -> AI Router -> Switch Route
-> Tool Branches -> AI Synthesizer or Direct Reply -> Telegram Send + Save Memory + Save LLM Usage + Execution Logs
```

Do not create a multi-agent system.

## LLM Usage Policy

- Default path: two LLM calls per handled message - `AI Router` then `AI Synthesizer`.
- Fast-path exception: `finance_add`, `reminder_add`, and simple `ai_cost_report` responses may skip `AI Synthesizer` and use deterministic direct replies from Code / SQL output.
- Fast-path exception: simple `chat` / greeting responses may also skip `AI Synthesizer` when `AI Router` returns a short `direct_response`.
- `research` route may use two extra LLM nodes: `Research Planner` and `Research Interpreter`.
- `analysis` route may use one extra LLM node: `Analysis Interpreter`.
- `task_plan` route may use one extra LLM node: `Task Planner`.
- Do not add planner-executor loops or self-calling agent chains.

## Input Entry

Use polling, not Telegram webhooks, for local MVP.

```text
Schedule Trigger -> Load Telegram Poll State -> Telegram getUpdates -> Normalize Updates
-> Save Poll State Immediately -> Register Processed Update -> Gate Duplicate Updates
-> Gate Allowed Users -> Switch Input Kind
```

Required fields to preserve:

- `user_id`
- `chat_id`
- `message_id`
- `user_message`
- `received_at`
- `telegram_update_id`
- `message_kind`
- `voice_file_id`
- `is_allowed`

## Business Idempotency

Use `processed_telegram_updates` with `telegram_update_id` as the unique key.

- `telegram_poll_state` means transport acknowledgement.
- `processed_telegram_updates` means business event already claimed.

## Access Control

Gate allowed users before:

- voice download
- transcription
- router
- Tavily
- finance/reminder/task tools

Use `TELEGRAM_ALLOWED_USER_IDS`.

## Input Kind

Use a switch before memory/router:

- `text` and `unsupported` -> text path
- `voice` -> Telegram `getFile` -> download -> OpenAI transcription -> normalized text path

Unsupported input should return a normal user-facing explanation.

## Memory Policy

`Load Memory` must return two bounded memory views plus `user_profile`.

- `router_memory`: compact intent context, typically 2-4 recent rows trimmed to roughly 300-800 characters each
- `synth_memory`: richer conversational context, typically 4-6 recent rows trimmed to roughly 1000-1500 characters each
- `memory`: keep as compatibility alias for `synth_memory` until every downstream node is migrated

Each memory item includes:

- `role`
- `content`
- `created_at`

Also attach `user_profile` from PostgreSQL or default to `Pavlodar, Kazakhstan`.

## AI Router

Use a cheap OpenAI model such as `gpt-5.4-mini`.

The router must return valid JSON only.

Expected shape:

```json
{
  "route": "chat",
  "confidence": 0.9,
  "extracted_data": {}
}
```

Allowed routes:

- `finance_add`
- `finance_report`
- `search`
- `research`
- `analysis`
- `task_plan`
- `reminder_add`
- `ai_cost_report`
- `chat`

Routing guidance:

- `finance_report`: factual totals, lists, grouped numbers
- `search`: fresh web lookup or short web-grounded answer
- `research`: fuller web-based analysis, comparison, recommendation, or ready-to-read report
- `analysis`: trends, comparisons, anomalies, "why", mixed interpretation
- `task_plan`: sequential, scenario-based, or explicitly multi-step tasks that need bounded decomposition before execution

For `task_plan`, router should populate:

- `goal`
- optional `constraints`
- `reason`

If unsure, choose `chat`.

## Switch Route

Switch outputs must include:

- `chat`
- `search`
- `research`
- `finance_add`
- `finance_report`
- `reminder_add`
- `ai_cost_report`
- `analysis`
- `task_plan`

## Placeholder UX

Slow routes should send a temporary Telegram placeholder and edit it into the final answer:

```text
Switch Route -> Send Placeholder -> Placeholder Context -> Slow Tool Branch
Final Telegram Send -> editMessageText when placeholder_message_id exists, else sendMessage
```

Apply this only to slower routes:

- `search`
- `research`
- `analysis`
- `task_plan`

Do not use placeholder messages for fast confirmations such as `chat` direct responses, `finance_add`, `reminder_add`, or `ai_cost_report`.

Store placeholder state in `telegram_response_placeholders` keyed by `execution_id`. Placeholder send/save/update operations should use `continueOnFail` so the helper UX never blocks the main answer.

## Tool Branch Rules

Tool branches should stay deterministic where possible.

Every branch must output a stable `tool_data` object:

```json
{
  "type": "finance_report",
  "success": true,
  "error": null
}
```

If a branch fails, still continue to a user-facing response.

### Chat

No external tool. Return a minimal `tool_data`.

### Search

Use `Search Context Builder` before Tavily.

- honor `search_scope`
- apply `user_profile` defaults for local search
- append location hints only when needed

### Research

Allowed flow:

```text
Router -> Research Planner -> Research Query Builder -> Research Tavily Search -> Research Analysis Input -> Research Interpreter -> Tool Data Research -> Direct Reply Builder
```

Rules:

- use `research` when the user wants a web-based comparison, recommendation, shortlist, memo, or structured report
- `Research Planner` should produce a compact query + comparison criteria, not findings
- `Research Interpreter` should return structured JSON with:
  - `goal`
  - `what_found`
  - `comparison`
  - `conclusion`
  - `recommendations`
  - `sources`
  - optional `caveats`
- synthesizer should render research in a stable report format with these sections:
  - `Цель`
  - `Топ-5` or `Что найдено`
  - `Сравнение`
  - `Вывод`
  - `Рекомендация`
  - `Источники`
### Finance Add

Insert one transaction into `finance_log`.

If the tool result is already user-ready, prefer deterministic direct reply instead of `AI Synthesizer`.

### Finance Report

Return raw structured totals from `finance_log`.

### Reminder Add

Insert one reminder into `reminders`.

If the tool result is already user-ready, prefer deterministic direct reply instead of `AI Synthesizer`.

### AI Cost Report

Read aggregates from `llm_usage_log`.

Simple cost summaries may bypass `AI Synthesizer` and use deterministic direct reply.

### Analysis

Allowed flow:

```text
Router -> Time Range Builder -> SQL / Tavily -> Analysis Packager -> Analysis Interpreter -> Synthesizer
```

`Analysis Interpreter` must:

- return JSON only
- not invent numbers
- rely only on packaged datasets

### Task Plan

Allowed flow:

```text
Router -> Task Planner -> Task Plan Tool Data -> Synthesizer
```

Rules:

1. `Task Planner` may use one LLM call and must return JSON only.
2. Planner output is bounded to at most 3 explicit steps.
3. The planner is planning-only in the MVP chat workflow.
4. If a task is too large, planner output must set `requires_async = true`.

Expected planner output shape:

```json
{
  "goal": "",
  "requires_async": false,
  "steps": [
    { "step": 1, "type": "fetch_data", "description": "" },
    { "step": 2, "type": "compute", "description": "" },
    { "step": 3, "type": "summarize", "description": "" }
  ],
  "notes": []
}
```

## Context Shape

All branches should preserve or return this shape where practical:

```json
{
  "user_id": 123,
  "chat_id": 123,
  "message_id": 456,
  "user_message": "text",
  "route": "finance_report",
  "extracted_data": {},
  "router_memory": [],
  "synth_memory": [],
  "memory": [],
  "user_profile": {},
  "tool_data": {}
}
```

## AI Synthesizer

The synthesizer receives:

- `user_message`
- `synth_memory` or fallback `memory`
- `route`
- `extracted_data`
- `tool_data`

It must output plain text suitable for Telegram.

## Direct Reply

Use deterministic direct replies when:

- the branch already produced a complete confirmation
- no extra narrative quality is needed
- skipping the second LLM materially reduces latency and token usage

Typical candidates:

- `finance_add`
- `reminder_add`
- simple `ai_cost_report`
- simple `chat` / greeting with router-supplied `direct_response`

## Persistence

After final response generation:

- save user + assistant messages to `chat_memory`
- log `router`, `synthesizer`, `analysis_interpreter`, `research_interpreter`, and `task_planner` usage to `llm_usage_log` when usage metadata exists
- log tool latency and status to `tool_execution_log`
- save failed Telegram sends to `unsent_telegram_messages`
- write `execution_log` for accepted business events

## Future Layer

Longer-running execution is intentionally separate from MVP chat.

Future path:

```text
route = task_plan
Cron-based Task Runner executes one atomic step per run
```

Do not turn planning into the main operating loop inside the chat workflow.

