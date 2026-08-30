# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **minimal example** of a Go Slackbot that uses the Coder chat API's **dynamic tools** feature to let an LLM interact with Slack. Fork it, customize the system prompt, add your own tools. One file (`main.go`), zero abstractions — the goal is legibility, not production hardening.

## Build and run

```bash
# Build
go build -o slackbot .

# Run (requires five env vars)
SLACK_BOT_TOKEN=xoxb-...         \
SLACK_APP_TOKEN=xapp-...         \
CODER_URL=https://...            \
CODER_SESSION_TOKEN=...          \
CODER_ORGANIZATION_ID=<org-uuid> \
./slackbot
```

Get a session token with `coder tokens create`. Find your org UUID with `curl -H "Coder-Session-Token: $TOKEN" $CODER_URL/api/organizations` (or `coder organizations list`).

No lint, test, or vet target is configured. The repo has no test files by design. `go build` is the only verification gate.

## Environment

The process reads exactly five env vars at startup (`main.go:300-326` — `mustEnv` fatals on miss):

| Var | Source | Purpose |
|-----|--------|---------|
| `SLACK_BOT_TOKEN` | Slack app → OAuth & Permissions | Bot user token (`xoxb-…`) |
| `SLACK_APP_TOKEN` | Slack app → Basic Information → App-Level Tokens | Socket Mode token (`xapp-…`) |
| `CODER_URL` | Coder deployment | e.g. `https://your-coder.example.com` |
| `CODER_SESSION_TOKEN` | `coder tokens create` | Bearer for the Coder SDK |
| `CODER_ORGANIZATION_ID` | `coder organizations list` | UUID of the org the chat belongs to |

The bot's own Slack user ID is detected at startup via `api.AuthTestContext` and used to strip bot mentions from incoming text.

## Deploy as a systemd service

`scripts/install-andribot.sh` encapsulates the [dev.to guide](https://dev.to/ducnt114/running-golang-program-as-systemd-service-in-ubuntu-3k7j): builds the binary into `/opt/andribot`, renders `/etc/systemd/system/andribot.service`, runs `daemon-reload` + `enable` + `restart`. Idempotent. Secrets come from `/etc/andribot.env` (preferred — keeps tokens out of shell history) or as positional arguments:

```bash
sudo tee /etc/andribot.env >/dev/null <<'EOF'
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
CODER_URL=https://your-coder.example.com
CODER_SESSION_TOKEN=...
CODER_ORGANIZATION_ID=<org-uuid>
EOF
sudo chmod 600 /etc/andribot.env
sudo ./scripts/install-andribot.sh
sudo journalctl -u andribot -f
```

## Architecture (single file, read in this order)

`main.go` is one package. The data flow:

1. **`main` (line 294)** — parse env, build `*slack.Client`, build `*codersdk.ExperimentalClient`, drop into a socket-mode event loop.
2. **`handleMention` (line 371)** — fires on every `app_mention` event. Looks for an existing Coder chat via the `slack_thread` label; if none, creates one with the bot's dynamic tools attached. **This is the entry point that talks to the Coder API.**
3. **`watchChats` (line 532)** — a second goroutine subscribes to the global chat-watch stream. For every `ActionRequired` event, it dispatches each `ToolCall` to the matching `b.toolMap[tc.ToolName]` handler, then POSTs results back. Runs forever, reconnects on stream error.
4. **`dynamicTools` (line 99)** — returns the six tool definitions the LLM can invoke. Each is `codersdk.NewDynamicTool(name, description, handler)`. Handlers receive a `context.Context`, the typed args struct, and a `DynamicToolCall`, and return `(DynamicToolResponse, error)`.

### Important types

- `bot` (line 238) — holds the logger, Slack client, Coder client, bot UID, tool list, and a `userCache` (5-min TTL, RWMutex-guarded map). This is the shared mutable state of the program.
- `*userCache` (line 248) — per-user lookup cache. `lookupUser` is the only reader (line 282).
- Argument structs (`sendMessageArgs`, `editMessageArgs`, …, line 64-97) — JSON-serialized tool parameters. Each field has a `jsonschema:"required,…"` tag the LLM reads for its function-call schema.

### Slack mrkdwn conversion — `formatMessage` (line 621)

The LLM emits standard markdown; Slack uses its own `mrkdwn`. `formatMessage` is a small regex pipeline that:

1. Preserves fenced + inline code blocks (with language-tag stripping for ```go, ```js fences).
2. Converts `[text](url)` → `<url|text>` and `**bold**` → `*bold*`.
3. Converts `# Heading` → `*Heading*` (Slack has no headings).
4. Truncates at 3000 chars; the tool result carries a hint so the model sends a follow-up message.

This is the only piece of the code with non-trivial string manipulation. Touch with care.

### Thread ↔ chat lifecycle

Mentions in the same Slack thread always reuse the same Coder chat — keyed by `slack_thread:<channel>:<threadTs>`. The label is the join key (`main.go:392, 424, 440`). When the chat terminal status arrives via `watchChats`, `setStatus("")` clears the typing indicator.

## Codebase conventions in this example

- One file. Don't split until the user asks.
- `slog` over `log`. Errors via `logger.Error("context", "error", err)`, not `fmt.Println`.
- `sync.WaitGroup` for parallel Slack pre-fetches in `handleMention` (findChat + buildMessage race in parallel; `main.go:386-403`).
- Tool responses: wrap in `jsonResponse` (line 653) so handlers can `return jsonResponse(result)`. Slack errors inside tools are returned with `IsError: true` and a stringified message — Slack sees the failure but the tool loop continues.
- The `// ponytail:` comment style is encouraged for shortcuts (per global CLAUDE.md) — this example itself has none yet.

## The `systemPrompt` constant (line 24)

Edit this to change bot personality. Three blocks today:
- `<behavior>` — what to do (exactly what's asked).
- `<slack-status>` — forces the model to call `slack_report_status` before every other tool and to channel everything through `slack_send_message`.
- `<formatting-rules>` — Slack mrkdwn reference card (do/don't list).

Changes here ship as a new build — there's no runtime reload.

## Slack app setup

The manifest lives at `slack-app-manifest.yaml`. Required bot scopes:
`app_mentions:read`, `chat:write`, `reactions:write`, `channels:history`, `groups:history`, `users:read`, `users:read.email`, `assistant:write`. The last one powers the typing indicator (`SetAssistantThreadsStatusContext`).

Socket Mode must be enabled — the bot never exposes an HTTP endpoint.

## Coder API contract drift — known issue

The README pinned the SDK to commit `76d89f59af42` — the first commit with `WatchChats`, `UnsafeDynamicTools`, and the experimental chat APIs. The chat API is explicitly **experimental** ("highly experimental and highly subject to change" — `chats.go:391`).

`go.mod` is now pinned to **`v2.36.3`**, which adds the `OrganizationID` field on `CreateChatRequest`. The previous pin (`v2.33.0-rc.1`) would fail at runtime against newer Coder deployments with `400: organization_id is required` from `POST /api/experimental/chats`. The chat status enum also changed — `ChatStatusCompleted` was removed; the chat now transitions to `Error` or `RequiresAction` instead. The bot's "clear typing indicator when done" handler at `main.go:593` reflects both new states.

Expect further bumps. When `go mod tidy` errors on missing fields, the answer is almost always "the SDK added a field, update the call site". Read the [`chats.go` diff](https://github.com/coder/coder/commits/main/codersdk/chats.go) before bumping.

## Things to NOT do in this repo

- Don't add a framework, DI container, or interface abstractions. The whole point is one readable file.
- Don't add tests unless asked — the example is meant to be copy-pasted.
- Don't pin to a Coder SDK release tag yet — the experimental chat APIs are still changing; track a commit hash.
- Don't bind to a public HTTP port. Socket Mode keeps this bot stateless and firewalled.
