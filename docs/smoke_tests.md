# Smoke Tests

Use this checklist after syncing or changing the n8n workflows.

## Before Testing

- n8n is running and healthy: `http://localhost:5678/healthz`
- `Personal AI Assistant MVP` is active.
- `Reminder Delivery` is active if reminder delivery is being tested.
- Telegram user ID is present in `TELEGRAM_ALLOWED_USER_IDS`.
- PostgreSQL, OpenAI, Telegram, and Tavily credentials are assigned in n8n.

## Fast Checks

| Area | Telegram message | Expected route | Expected result |
|------|------------------|----------------|-----------------|
| Chat | `hello, who are you?` | `chat` | Short direct or synthesized intro without tool details. |
| Finance add | `spent 1500 on taxi` | `finance_add` | Confirms amount, category, currency, and expense type. |
| Finance report | `how much did I spend this week?` | `finance_report` | Shows totals for the requested period. |
| Search | `find the latest OpenAI news` | `search` | Gives a short current web-grounded answer with sources if available. |
| Research | `find the 5 best coffee shops nearby, compare rating, reviews and distance, then give a short recommendation` | `research` | Returns goal, top items, comparison, conclusion/recommendation, and sources. |
| Analysis | `analyze my spending for this month and tell me where I can cut costs` | `analysis` | Uses stored data and gives insights/recommendations without inventing numbers. |
| Reminder | `remind me tomorrow at 9 to call the doctor` | `reminder_add` | Confirms concrete local date/time and task text. |
| Task plan | `compare several monthly budget scenarios and propose a step-by-step action plan` | `task_plan` | Returns a bounded plan, not an open-ended autonomous execution. |

## Russian Message Set

The Russian smoke-test messages are kept in `docs/roadmap.md` under `Stage 4: Manual Tests`.

Use those when you want to test the exact primary language of the bot. Use the English messages above when you want an ASCII-safe checklist that will not suffer from Windows console encoding issues.

## Voice Checks

- Send a voice message with a normal chat question.
- Send a voice message like `spent 700 on coffee`.
- Send a voice message like `remind me in 2 minutes to drink water`.

Expected result: transcription succeeds, then the same route behavior as text input.

## Reminder Delivery Check

Send:

```text
remind me in 2 minutes to drink water
```

Expected result:

1. Main workflow confirms the reminder was saved.
2. Delivery workflow sends the reminder after roughly 2 minutes.
3. Reminder is marked delivered in PostgreSQL.

## Research Quality Check

Send:

```text
find the 5 best coffee shops nearby, compare rating, reviews and distance, then give a short recommendation
```

Good answer criteria:

- It goes through `research`, not plain `search`.
- It does not invent exact distance if sources do not provide it.
- It uses Telegram-friendly lines instead of a fragile markdown table.
- It includes at least one source or clearly says sources were unavailable.
- It gives a recommendation that follows from the comparison.
- For slower research, the temporary processing message is edited into the final answer instead of leaving an extra stale message.

## Analysis Quality Check

Send:

```text
analyze my spending for this month and tell me where I can cut costs
```

Good answer criteria:

- It uses database aggregates, not web search alone.
- It separates facts from recommendations.
- It does not invent categories, totals, or dates missing from the data.
- If there is not enough data, it says so directly.

## Negative Checks

| Case | Test | Expected result |
|------|------|-----------------|
| Unauthorized user | Send any message from a user not in allowlist. | Workflow stops before paid LLM/tool calls. |
| Unsupported input | Send a sticker or unsupported document. | Bot replies gracefully or logs unsupported input without crashing. |
| Tool/API failure | Temporarily break Tavily key or disable search credential. | Bot gives a graceful tool failure response and logs the error. |

## Execution Review

After a test message, inspect the latest n8n execution:

- Check `route` after `AI Router`.
- Check the selected branch after `Switch Route`.
- For `search`, `research`, `analysis`, and `task_plan`, confirm a placeholder node ran before the slow branch.
- For research, confirm `Research Planner`, `Research Tavily Search`, `Research Interpreter`, and `Tool Data Research` ran.
- For analysis, confirm `Analysis Time Range`, `Analysis Base SQL`, and `Analysis Interpreter` ran.
- Confirm `execution_log`, `tool_execution_log`, and `llm_usage_log` receive rows when applicable.
- If placeholder migration is applied, confirm `telegram_response_placeholders` receives a row and ends with status `final_sent`.

## Performance Targets

These are practical local MVP targets, not strict SLAs:

| Route | Expected feel |
|-------|---------------|
| `chat` direct response | Fast, usually a few seconds including polling delay. |
| `finance_add` / `reminder_add` | Fast, should usually bypass synthesizer. |
| `search` | Medium, depends on Tavily and one final answer step. |
| `research` | Slower, but should normally finish without multi-minute waits. |
| `analysis` | Medium to slow depending on SQL volume and interpreter call. |

If `research` regularly takes around 2 minutes, inspect Tavily latency, OpenAI latency, and whether the workflow is retrying or waiting on a failed branch.
