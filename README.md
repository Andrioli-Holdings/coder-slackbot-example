# Coder Slackbot Example

A minimal Go Slackbot that uses the [Coder chat API](https://coder.com/docs)'s **dynamic tools** feature to let an LLM interact with Slack. Powered by Coder.

## How It Works

1. Bot is @mentioned in Slack
2. Creates a new Coder chat with dynamic tools (`slack_send_message`, `slack_react_to_message`, etc.)
3. When the LLM calls a dynamic tool → executes it against the Slack API → submits results back
4. Chat resumes until complete

Follow-up mentions in the same thread reuse the same Coder chat.

## Dynamic Tools

| Tool | Description |
|------|-------------|
| `slack_send_message` | Post a message |
| `slack_edit_message` | Edit a previously sent message |
| `slack_react_to_message` | Add or remove an emoji reaction |
| `slack_get_thread_replies` | Read thread context |
| `slack_get_user_info` | Look up a Slack user |
| `slack_report_status` | Update the typing indicator |

## Running

```bash
export SLACK_BOT_TOKEN="xoxb-..."        # Bot User OAuth Token
export SLACK_APP_TOKEN="xapp-..."        # App-Level Token (socket mode)
export CODER_URL="https://your-coder.example.com"
export CODER_SESSION_TOKEN="..."         # coder tokens create

go build -o slackbot .
./slackbot
```

## Slack App Setup

1. Create a Slack app at https://api.slack.com/apps (or use the manifest in `slack-app-manifest.yaml`)
2. Enable **Socket Mode** (generates the `xapp-` token)
3. Subscribe to bot events: `app_mention`
4. Add bot scopes: `app_mentions:read`, `chat:write`, `reactions:write`, `channels:history`, `groups:history`, `users:read`, `users:read.email`, `assistant:write`
5. Install to workspace

## Requirements

- A Coder deployment with agents and chat enabled
- Go 1.24+
