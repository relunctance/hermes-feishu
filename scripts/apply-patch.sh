#!/bin/bash
# 一键应用 bot-to-bot 补丁
# 用法: bash ~/repos/hermes-feishu/scripts/apply-patch.sh

set -e

GATE_FILE="$HOME/.openclaw/extensions/openclaw-lark/src/messaging/inbound/gate.js"

if [ ! -f "$GATE_FILE" ]; then
    echo "ERROR: $GATE_FILE not found. Is openclaw-lark installed?"
    exit 1
fi

# 检查是否已经打过补丁
if grep -q "senderIsBot" "$GATE_FILE"; then
    echo "Patch already applied, skipping."
    exit 0
fi

echo "Applying bot-to-bot patch to $GATE_FILE ..."

# 备份
cp "$GATE_FILE" "${GATE_FILE}.bak.$(date +%Y%m%d%H%M%S)"

# 查找并替换
sed -i 's/if (requireMention \&\& !(\(0, mention_1\.mentionedBot\))(ctx)) {/\/\/ Allow bot-sent messages to bypass mention requirement (bot-to-bot collaboration)\n    const senderIsBot = ctx.rawSender?.sender_type === '\''app'\'';\n    if (requireMention \&\& !\1(ctx) \&\& !senderIsBot) {/' "$GATE_FILE"

if grep -q "senderIsBot" "$GATE_FILE"; then
    echo "Patch applied successfully."
    echo "Restarting openclaw-gateway..."
    systemctl --user restart openclaw-gateway
    echo "Done."
else
    echo "ERROR: Patch application failed. Restoring backup..."
    ls -t "$GATE_FILE".bak.* | head -1 | xargs -I{} cp {} "$GATE_FILE"
    exit 1
fi
