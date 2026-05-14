# n8n Local Troubleshooting (empty workflows, empty canvas, MCP vs JSON)

This page answers two common local-development issues and clarifies what MCP can and cannot do.

---

## 1. Why a “new” empty workflow appears every time

### Cause A — URL contains `?new=true`

If you open or bookmark a URL like:

```text
http://localhost:5678/workflow/<someId>/executions?new=true
```

n8n treats that as a **new / draft** context. You often land on an empty workflow such as **“My workflow N”** with **no nodes**.

**Fix**

- Remove `?new=true` from the address bar, or stop using that bookmark.
- Prefer opening workflows from the sidebar: **Workflows** → choose **Personal AI Assistant MVP** (or your real workflow name).

### Cause B — You click **New workflow** each time

Each click creates another empty workflow.

**Fix**

- Use **Workflows** list and select the existing MVP workflow instead of creating a new one.

### Cause C — Wrong workflow selected

The MVP lives as its **own** workflow record. If you open **“My workflow 3”**, that is **not** the imported MVP unless you renamed it.

**Fix**

- Find **Personal AI Assistant MVP** in the list (or note its `/workflow/<id>` URL after import).

### Cause D — Wrong tab

**Executions** shows **run history**, not the editor canvas. On first setup it may say “No executions” and look empty even though the workflow exists.

**Fix**

- Click **Editor** (not **Executions**) to see nodes and wires.

---

## 2. “Nothing shows” on the canvas after JSON import

Check these in order:

| Symptom | Likely cause | What to do |
|--------|----------------|------------|
| Blank canvas, URL has `?new=true` | New empty workflow | Open MVP from **Workflows** list; remove `?new=true`. |
| Blank area but sidebar shows workflow name | You are on **Executions** tab | Switch to **Editor**. |
| MVP workflow open but no wires between nodes | Connections missing after import | Run `python .\scripts\sync-mvp-workflow.py` with `N8N_API_KEY` in `.env` (see README **Sync graph + SQL from the repo**). |
| Nodes exist but Postgres fails | Credential not bound | **Credentials** → Postgres (`Host: postgres`), then assign it on **every** Postgres node in the workflow. |
| Import seemed to do nothing | Imported into wrong project / duplicate | Open **Workflows** list — look for **Personal AI Assistant MVP**; delete stray empty **My workflow N** copies if confusing. |

### About `personal_assistant_mvp.json`

The file in `workflows/personal_assistant_mvp.json` is a **standard n8n workflow export** (nodes + connections + settings). You do **not** convert it to “another format” manually — n8n imports it as JSON.

If the UI import behaves oddly, use either:

- **Logged CLI import** (full stdout/stderr + n8n container tail):  
  `.\scripts\import-mvp-docker-cli.ps1` — output goes to `logs/n8n-import-cli-*.log` (folder is gitignored).
- **Create via REST API with log file** (shows HTTP error bodies the UI hides):  
  `python .\scripts\create-mvp-workflow-api.py` — creates a **new** workflow and writes `logs/n8n-create-workflow-*.log`.
- Docker import steps manually (see `docs/n8n_setup.md`), or  
- REST **merge** into an existing id: `scripts/sync-mvp-workflow.py` (preserves server node IDs and credentials where possible).

**Why there is no “import error” in n8n:** the browser importer often fails validation without surfacing the response body. Use DevTools → **Network** → repeat import → inspect the failing request status and JSON error. The scripts above print the same information to disk.

---

## 3. Why MCP did not “configure everything” from JSON

There are **different** MCP servers:

1. **Official n8n MCP** (recommended for your instance): configured in Cursor with  
   `http://localhost:5678/mcp-server/http` and a **Bearer access token** from n8n (Settings → MCP).  
   It manages workflows via **tools** (search workflows, get details, update workflow from **Workflow SDK code**, etc.). It does **not** paste arbitrary JSON into the editor like a file import.

2. **Third-party `n8n-mcp` packages** (e.g. hosted `api.n8n-mcp.com`): different tools and often require linking **N8N_API_URL** + **N8N_API_KEY** in their dashboard — not the same as built-in n8n MCP.

3. **This repository**: the single source of truth for the graph is **`workflows/personal_assistant_mvp.json`**. The reliable way to align your running instance with that file locally is:

   - Assign Postgres credentials once in the UI (secrets cannot be invented by MCP).  
   - Run **`scripts/sync-mvp-workflow.py`** when connections/parameters drift.

**Secrets**

- Telegram / OpenAI / Tavily keys live in **`.env`** for Docker (`docker-compose.yml`) and/or in **n8n Credentials**. No MCP can safely guess them.

---

## Quick checklist (local MVP)

1. `docker compose up -d` — n8n reachable at `http://localhost:5678`.
2. Open **Workflows** → **Personal AI Assistant MVP** → tab **Editor** (no `?new=true` in URL).
3. Postgres credential on all Postgres nodes (`Host: postgres`).
4. `.env` loaded into containers (Telegram, OpenAI, Tavily).
5. Optional: `N8N_API_KEY` + `python .\scripts\sync-mvp-workflow.py` if wires/SQL are wrong.
6. **Execute workflow** from **Editor** after nodes are visible; only then enable **Active**.

---

## Questions?

If something still fails, capture:

- Full browser URL (you may redact tokens).
- Whether you are on **Editor** or **Executions**.
- Workflow **name** as shown in the left list (exact title).
- Last execution error (node name + message from **Executions** detail).
