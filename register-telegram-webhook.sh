#!/bin/bash
# Register or remove Telegram webhook for n8n.
#
# REGISTER:
#   TELEGRAM_BOT_TOKEN=xxx \
#   WEBHOOK_URL=https://n8n.yourdomain.com/webhook/telegram \
#   bash register-telegram-webhook.sh
#
# REMOVE (revert to polling):
#   TELEGRAM_BOT_TOKEN=xxx bash register-telegram-webhook.sh --delete

set -e

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?ERROR: Set TELEGRAM_BOT_TOKEN}"
API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

parse_response() {
  python3 -c "
import sys, json
r = json.load(sys.stdin)
if r.get('ok'):
    print('OK:', r.get('description', 'success'))
else:
    print('FAIL:', json.dumps(r.get('error_code'), r.get('description')))
    sys.exit(1)
"
}

if [ "${1}" = "--delete" ]; then
  echo "=== Removing webhook (bot reverts to polling) ==="
  curl -s -X POST "${API}/deleteWebhook" | parse_response
  exit 0
fi

WEBHOOK_URL="${WEBHOOK_URL:?ERROR: Set WEBHOOK_URL (e.g. https://n8n.yourdomain.com/webhook/telegram)}"

echo "=== Registering Telegram webhook ==="
echo "  URL: ${WEBHOOK_URL}"
echo ""

curl -s -X POST "${API}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{
    \"url\": \"${WEBHOOK_URL}\",
    \"allowed_updates\": [\"message\", \"callback_query\", \"voice\"]
  }" | parse_response

echo ""
echo "=== Webhook status ==="
curl -s "${API}/getWebhookInfo" | python3 -c "
import sys, json
r = json.load(sys.stdin)['result']
print('  URL           :', r.get('url') or '(none)')
print('  Pending       :', r.get('pending_update_count', 0))
print('  Max connections:', r.get('max_connections', '-'))
if r.get('last_error_message'):
    print('  Last error    :', r['last_error_message'])
else:
    print('  Health        : OK')
"
