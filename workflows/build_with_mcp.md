# Build Personal Assistant Workflow with n8n MCP

Use this prompt with Cursor or Codex when `n8n-mcp` is connected and authenticated.

```text
Read the project files:
- docs/architecture_mcp.md
- docs/database_schema.md
- docs/ai_prompts.md
- docs/n8n_setup.md

Create the MVP n8n workflow for the personal AI assistant.

Strict architecture:
Telegram Polling Entry -> Save Poll State Immediately -> Idempotency Check -> Gate Allowed Users -> Switch Input Kind -> Text/Voice Processing -> Load Memory -> AI Router -> Switch Route -> Tool Branches -> AI Synthesizer or Direct Reply -> Telegram Send + Save Memory + Save LLM Usage + Execution Logs

Runtime decisions:
- local n8n in Docker
- PostgreSQL host inside n8n: postgres
- PostgreSQL database: personal_ai_assistant
- search provider: Tavily
- Telegram mode: polling through Telegram Bot API getUpdates
- Telegram access control: use TELEGRAM_ALLOWED_USER_IDS early
- voice input: Telegram voice -> getFile -> download -> OpenAI transcription -> normal text path
- business idempotency: processed_telegram_updates with telegram_update_id UNIQUE
- observability: execution_log, tool_execution_log, llm_usage_log, unsent_telegram_messages
- no multi-agent design
- allow direct deterministic replies for simple `finance_add`, `reminder_add`, and `ai_cost_report` confirmations
- allow `analysis` to use one extra `Analysis Interpreter` LLM node
- allow `task_plan` to use one extra `Task Planner` LLM node that only returns a bounded plan

Routes:
- finance_add
- finance_report
- search
- analysis
- task_plan
- reminder_add
- ai_cost_report
- chat

Use the SQL from docs/database_schema.md.
Use prompts from docs/ai_prompts.md.
Use Tavily HTTP Request for search.
Preserve user_id, chat_id, message_id, user_message, message_kind, route, extracted_data, memory, and tool_data through all branches.
Add graceful error handling so failed tool branches still go to AI Synthesizer.
Log router, synthesizer, analysis_interpreter, research_interpreter, and task_planner usage to llm_usage_log when usage metadata exists.
Log accepted business executions to execution_log.
Log tool latency and success/error to tool_execution_log.
If Telegram send fails after retries, save the generated response to unsent_telegram_messages.

Polling entry details:
- Use Schedule Trigger, not Telegram Trigger, for local MVP.
- Load last_update_id from telegram_poll_state.
- Call Telegram getUpdates with offset = last_update_id + 1.
- Process message updates with text, voice, or unsupported content.
- Normalize output to user_id, chat_id, message_id, user_message, message_kind, voice_file_id, is_allowed, received_at, telegram_update_id.
- Update telegram_poll_state immediately after normalizing an update, before allowlist, voice download, OpenAI, Tavily, or other tool branches.
- Register processed_telegram_updates after poll state save. If INSERT ON CONFLICT returns no row, skip the duplicate update.
- Use Switch Input Kind to send voice messages through transcription and text/unsupported messages through the normal context path.
- Use Switch Route for finance_add, finance_report, search, analysis, task_plan, reminder_add, ai_cost_report, and chat.
```

After creation, test with:

```text
привет, кто ты?
потратил 1500 на такси
сколько я потратил за неделю?
найди последние новости про OpenAI
напомни завтра в 9 позвонить врачу
<голосовое сообщение с расходом или напоминанием>
```
