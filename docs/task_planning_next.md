# Task Planning Layer: Next Architecture Step

This document defines the future task planning layer. It is not part of the current MVP workflow yet.

## Current MVP

The current workflow is intentionally simple:

```text
Telegram Polling Entry
-> Load Memory
-> GPT-5.4 mini Router
-> Deterministic Tool Branches
-> GPT-5.4 mini Synthesizer
-> Save Memory
-> Telegram Send
```

This is a stateless agent with controlled tool execution.

## Core Rule

The planner must not become the core operating system.

It should be an optional tool route:

```text
route = task_plan
```

Do not build:

```text
Planner -> Executor -> Planner -> Executor -> ...
```

for the MVP. That creates runaway token usage and unstable behavior.

## Recommended Two-Workflow Design

### Workflow 1: Chat Intake

```text
Telegram Polling Entry
-> Router
-> Guard
-> Tools, including optional task_plan
-> Synthesizer
-> Reply
```

### Workflow 2: Task Runner

```text
Cron
-> Load Active Tasks
-> Pick One Next Step
-> Execute One Step
-> Update Task State
-> Exit
```

The Task Runner must do one atomic step per run and then stop.

## Guardrails

Use these hard limits:

```text
max_planning_steps_per_message = 1
max_tool_calls_per_message = 5
max_task_depth = 3
max_replan_per_task = 2
max_task_revisions = 3
agent_never_calls_itself = true
planner_only_writes_plan = true
executor_runs_only_explicit_tasks = true
```

If a task hits its limit, stop automatic planning and ask the user.

## Future Tables

Add these later, not in the current MVP:

```text
tasks
task_events
task_dependencies
```

Minimum task states:

```text
planned
active
blocked
done
cancelled
```

Minimum task fields:

```text
id
user_id
chat_id
parent_task_id
title
description
status
priority
depth
revision_count
replan_count
last_planned_at
next_run_at
created_at
updated_at
```

## Why This Design

- No infinite planning loops.
- State is explicit in PostgreSQL.
- AI is used only at controlled decision points.
- Work can resume through Cron without long-running executions.
- The system can grow into a task graph later without rewriting the MVP.

