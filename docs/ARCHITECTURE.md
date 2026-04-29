# Hermes 飞书 Bot-to-Bot 架构说明

## 问题

Hermes Bot 在飞书群里运行时：
- ✅ 人 @ 机器人 → 正常回复
- ❌ 机器人 → 机器人 → 接收方不回复

## 根因分析

### 消息流向

```
飞书服务器 → openclaw-gateway (WebSocket) → openclaw-lark (协议层) → Hermes (AI层)
```

`openclaw-lark` 是飞书协议适配层，负责接收飞书 WebSocket 事件并转换为统一格式交给 Hermes。

### requireMention 机制

在 `gate.js` 中，群聊消息有一个 `requireMention` 规则：

```
群聊消息 → gate() → 检查是否@机器人 → 未@则拒绝 (no_mention)
```

这是为了过滤群里的噪音消息（只响应被 @ 的消息）。

### Bot-to-Bot 失败根因

Bot 发消息时，**同样没有 @ 接收方 bot**。所以：

```
Bot-A 发消息给 Bot-B → gate() → 未@Bot-B → 被拒绝 (no_mention) → Bot-B 不回复
```

### sender_type 区分

飞书事件中 `sender.sender_type` 字段区分发送者类型：

| sender_type | 发送者 |
|-------------|--------|
| `user` | 人类用户 |
| `app` | Bot/应用 |

数据来源：`event.sender.sender_type`（飞书 SDK 原始字段）

## 修复方案

在 `gate.js` 的 `requireMention` 检查中，增加 bot 例外：

```javascript
// gate.js:171-173
const senderIsBot = ctx.rawSender?.sender_type === 'app';
if (requireMention && !(0, mention_1.mentionedBot)(ctx) && !senderIsBot) {
    // 拒绝 (no_mention)
}
```

**逻辑**：如果发送者是 bot，即使没有 @ 也放行。这样 bot-to-bot 消息不会被误杀。

## 为什么不在 mention.js 修复

`mentionedBot()` 只检查消息中是否 @ 了**当前 bot**（自己）。

对于 bot-to-bot 场景：
- Bot-A 发消息给 Bot-B
- Bot-B 检查：`mentionedBot(Bot-B)` → 消息里没有 @Bot-B → false
- 即使修复 `mentionedBot()` 也无法让 Bot-B 知道自己被呼叫

所以在 `gate.js` 层用 `senderIsBot` 绕过 `requireMention` 是最干净的方案。

## 文件位置

```
~/.openclaw/extensions/openclaw-lark/src/messaging/inbound/
├── gate.js        ← 补丁目标文件
├── mention.js     # mentionedBot() 函数
├── parse.js       # 消息解析，rawSender 在此注入
└── enrich.js      # 发送者信息丰富化
```

## 注意事项

### 1. openclaw 已卸载

截至 2026-04-29，openclaw 已从系统中移除。本补丁基于最后版本的 openclaw-lark 扩展。

如果重装 openclaw：
1. 重新安装 openclaw-lark 扩展
2. 重新应用本补丁

### 2. 飞书升级

飞书 SDK 升级可能会改变 `sender_type` 的字段名或值，需重新验证。

### 3. Self-filter（屏蔽自己）

当前补丁**不屏蔽自己发消息**。即 Bot-A 发消息，Bot-A 不会收到自己的消息（因为发送者是自己，不走 gate 逻辑）。这是正常行为。

### 4. 日志验证

打补丁后，查看网关日志：
```bash
journalctl --user -u openclaw-gateway -f | grep "no_mention\|senderIsBot"
```

正常情况下，bot-to-bot 消息不再出现 `no_mention` 拒绝。

## 相关文件

- 补丁文件：`patch/gate-bot-to-bot.patch`
- 技能手册：`skill/SKILL.md`
- 一键脚本：`scripts/apply-patch.sh`
