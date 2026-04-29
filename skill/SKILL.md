---
name: hermes-feishu-bot-to-bot
description: |
  飞书 Bot-to-Bot 通信补丁。当 Hermes Bot 在飞书群聊中发消息给其他 Bot 时，
  接收方不回复的问题修复。

  **触发条件**：
  (1) Bot 在飞书群里发消息，另一个 Bot 不回复
  (2) 用户问"为什么 bot 之间不回答"
  (3) 飞书/OpenClaw 版本升级后 bot-to-bot 失效
  (4) 新部署 Hermes + 飞书环境

  **前置条件**：openclaw-gateway + openclaw-lark 已安装
---

# Hermes 飞书 Bot-to-Bot 补丁

## 问题现象

- 人 @ 机器人 → 正常回复 ✓
- 机器人发消息给另一个机器人 → **另一个机器人不回复** ✗

## 根因

`gate.js` 的 `requireMention=true` 群聊规则：未 @机器人 的消息直接拒绝（`no_mention`）。
Bot 发消息时同样没有 @，所以 bot→bot 的消息被误杀。

**关键判断**：`sender_type === 'app'` → bot；`sender_type === 'user'` → 人

## 修复步骤

### Step 1: 确认文件路径

```
~/.openclaw/extensions/openclaw-lark/src/messaging/inbound/gate.js
```

### Step 2: 定位代码（行号 ~171）

找到：
```javascript
if (requireMention && !(0, mention_1.mentionedBot)(ctx)) {
```

### Step 3: 替换为

```javascript
// Allow bot-sent messages to bypass mention requirement (bot-to-bot collaboration)
const senderIsBot = ctx.rawSender?.sender_type === 'app';
if (requireMention && !(0, mention_1.mentionedBot)(ctx) && !senderIsBot) {
```

### Step 4: 重启网关

```bash
systemctl --user restart openclaw-gateway
```

### Step 5: 验证

让一个 bot 在群里发消息，@ 另一个 bot，确认有回复。

## 飞书升级后

飞书 SDK/OpenClaw 重装会覆盖 `gate.js`，需要重新应用补丁。

## 自动化

```bash
# 一键应用
bash ~/repos/hermes-feishu/scripts/apply-patch.sh
```

## 注意事项
## 已知限制（2026-04-29）

### wk-hermes / mao 不响应排查路径

wk-hermes 和 mao 对 @mention 无响应，但 bailong-hermes 正常。排查顺序：

1. **确认 bot 是否在群里** — 在飞书管理后台检查 bot 是否被添加到对应群
2. **确认 WebSocket 订阅** — wk-hermes/mao 的 Feishu WebSocket 是否真的订阅了该群（不是只改 config.yaml 就生效）
3. **检查日志** — bailong-hermes 的日志在 `~/.hermes/logs/agent.log`，wk-hermes 的日志路径需向 wukong 确认
4. **对比实验** — 在已知正常的群（oc_629f6534bd95cc0730b791f8a1456397）发消息测试
5. **群 ID 是否一致** — 不同 bot 的 app_token 不同，同一个群对不同 bot 的 chat_id 可能不同

### env 不生效的坑

`FEISHU_FREE_RESPONSE_CHATS` / `FEISHU_FREE_RESPONSE_CHANNELS` 是**旧版 openclaw** 的变量，**不影响 Hermes bailong** 的行为。 Hermes 的免@配置只在 `config.yaml` 的 `group_rules[chat_id].at_only: false`。

### 飞书 bot 身份查询

```bash
BOT_TOKEN=$(curl -s -X POST 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal' \
  -H 'Content-Type: application/json' \
  -d '{"app_id": "<APP_ID>", "app_secret": "<APP_SECRET>"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["tenant_access_token"])')
curl -s "https://open.feishu.cn/open-apis/bot/v3/info" -H "Authorization: Bearer $BOT_TOKEN"
```

### 当前状态（2026-04-29）

- bailong-hermes：`at_only: false`，免@响应正常 ✓
- wk-hermes：配置正确但未确认是否收得到 oc_22e019265c6096916f5a78de44f3cdea 的消息
- mao：未确认是否在 oc_22e019265c6096916f5a78de44f3cdea 群

## 注意事项
- openclaw 已卸载（2026-04-29），补丁存放在 `~/repos/hermes-feishu/patch/`
- 如果重装 openclaw，需重新安装 openclaw-lark 扩展
- 不需要重新编译，src 目录的 .js 文件是直接运行时代码
