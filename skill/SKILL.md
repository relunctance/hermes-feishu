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

- openclaw 已卸载（2026-04-29），补丁存放在 `~/repos/hermes-feishu/patch/`
- 如果重装 openclaw，需重新安装 openclaw-lark 扩展
- 不需要重新编译，src 目录的 .js 文件是直接运行时代码
