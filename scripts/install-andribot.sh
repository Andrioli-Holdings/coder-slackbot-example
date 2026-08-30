#!/usr/bin/env bash
# Install andribot as a systemd service on Ubuntu.
# See https://dev.to/ducnt114/running-golang-program-as-systemd-service-in-ubuntu-3k7j
#
# Usage:
#   sudo ./scripts/install-andribot.sh                       # reads /etc/andribot.env
#   sudo ./scripts/install-andribot.sh <bot> <app> <url> <token> <org_uuid>
#
# The /etc/andribot.env file should export:
#   SLACK_BOT_TOKEN, SLACK_APP_TOKEN, CODER_URL, CODER_SESSION_TOKEN, CODER_ORGANIZATION_ID
#
# Idempotent: safe to re-run; will rebuild and restart on every invocation.

set -euo pipefail

ENV_FILE=/etc/andribot.env
INSTALL_DIR=/opt/andribot
SERVICE_FILE=/etc/systemd/system/andribot.service
SERVICE_NAME=andribot

# --- Load secrets ----------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
  set -a; . "$ENV_FILE"; set +a
  for v in SLACK_BOT_TOKEN SLACK_APP_TOKEN CODER_URL CODER_SESSION_TOKEN CODER_ORGANIZATION_ID; do
    if [[ -z "${!v:-}" ]]; then
      echo "missing $v in $ENV_FILE" >&2; exit 1
    fi
  done
elif [[ $# -eq 5 ]]; then
  SLACK_BOT_TOKEN=$1
  SLACK_APP_TOKEN=$2
  CODER_URL=$3
  CODER_SESSION_TOKEN=$4
  CODER_ORGANIZATION_ID=$5
else
  echo "usage: $0                          # reads $ENV_FILE" >&2
  echo "       $0 <bot> <app> <url> <session> <org_uuid>" >&2
  exit 1
fi

# --- Preflight -------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "must run as root (systemd unit + /opt write access)" >&2; exit 1
fi
command -v go     >/dev/null || { echo "go not found in PATH" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemctl not found (Ubuntu only?)" >&2; exit 1; }

# --- Place binary ----------------------------------------------------------
SRC=$(cd "$(dirname "$0")/.." && pwd)
echo ">> building $SERVICE_NAME from $SRC"
( cd "$SRC" && go build -o "$INSTALL_DIR/$SERVICE_NAME" . )

# --- Render unit -----------------------------------------------------------
echo ">> writing $SERVICE_FILE"
umask 077
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AndrioBot Slackbot Service
ConditionPathExists=$INSTALL_DIR
After=network.target

[Service]
Type=simple
User=root
Group=root

WorkingDirectory=$INSTALL_DIR
Environment="SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN}"
Environment="SLACK_APP_TOKEN=${SLACK_APP_TOKEN}"
Environment="CODER_URL=${CODER_URL}"
Environment="CODER_SESSION_TOKEN=${CODER_SESSION_TOKEN}"
Environment="CODER_ORGANIZATION_ID=${CODER_ORGANIZATION_ID}"
ExecStart=$INSTALL_DIR/$SERVICE_NAME
Restart=on-failure
RestartSec=10

StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

# --- Activate --------------------------------------------------------------
echo ">> reloading systemd and restarting $SERVICE_NAME"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# --- Status ----------------------------------------------------------------
sleep 1
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo ">> $SERVICE_NAME is active — journalctl -u $SERVICE_NAME -f to follow logs"
else
  echo "!! $SERVICE_NAME failed to start — systemctl status $SERVICE_NAME for details" >&2
  exit 1
fi
