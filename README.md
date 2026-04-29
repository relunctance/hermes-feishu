# hermes-feishu

飞书 channel 层补丁：让 Hermes Bot 之间可以在群聊中互相通信（bot-to-bot）。

## 问题

当 Hermes 通过飞书群聊运行时，**人 @ 机器人** 可以正常回复，但**机器人发消息给另一个机器人**时，接收方的 `requireMention=true` 会拒绝处理（`no_mention`），导致 bot-to-bot 无法通信。

## 根因

`openclaw-lark` 扩展的 `gate.js` 中，群聊消息处理逻辑：

```javascript
// 原代码
if (requireMention && !(0, mention_1.mentionedBot)(ctx)) {
    return { allowed: false, reason: 'no_mention' };
}
```

当 `requireMention=true` 时，所有未 @机器人的消息都被拒绝。但 bot 发消息时同样没有 @，所以 bot→bot 的消息被误杀。

## 修复

在 `gate.js:173` 增加 bot 发消息的例外：

```javascript
// Allow bot-sent messages to bypass mention requirement (bot-to-bot collaboration)
const senderIsBot = ctx.rawSender?.sender_type === 'app';
if (requireMention && !(0, mention_1.mentionedBot)(ctx) && !senderIsBot) {
    return { allowed: false, reason: 'no_mention' };
}
```

- `sender_type === 'app'` → 发送者是 bot
- `sender_type === 'user'` → 发送者是人类

## 文件结构

```
hermes-feishu/
├── README.md              # 本文件
├── patch/
│   └── gate-bot-to-bot.patch  # 完整 diff
├── skill/
│   ├── SKILL.md           # 操作手册
│   └── references/
│       └── bot-sender-type.png  # 飞书 sender_type 说明
├── scripts/
│   └── apply-patch.sh     # 一键应用补丁
└── docs/
    └── ARCHITECTURE.md     # 详细架构说明
```

## 应用补丁

```bash
# 方式1：一键脚本
bash scripts/apply-patch.sh

# 方式2：手动应用
# 编辑 ~/.openclaw/extensions/openclaw-lark/src/messaging/inbound/gate.js
# 找到 gate.js:171-173 行的 if 语句，插入 bot 例外逻辑
```

## 重启网关

```bash
systemctl --user restart openclaw-gateway
```

## 飞书升级后需重新应用

飞书 SDK/OpenClaw 版本升级后，`gate.js` 会被覆盖，需要重新应用补丁。

## 注意事项

- openclaw 已卸载（2026-04-29），本补丁基于 `.openclaw/extensions/openclaw-lark/src/messaging/inbound/gate.js`
- 如果 OpenClaw 重装，需重新从源码编译或重新安装 openclaw-lark 扩展
