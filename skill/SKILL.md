---
name: hermes-feishu-bot-to-bot
description: |
  飞书 Bot-to-Bot 免@广播模式修复。当 Hermes Bot 在飞书群聊中被另一个 Bot @ 时，
  接收方不回复的问题。

  **触发条件**：
  (1) Bot @ Bot → 接收方不响应
  (2) 用户问"为什么 bot 之间不回答"
  (3) wk-hermes / mao 对 bailong-hermes 的 @mention 无响应
  (4) 部署新 bot 后 bot-to-bot 不通

  **前置条件**：Hermes gateway 运行中（不是 openclaw）
---

# Hermes 飞书 Bot-to-Bot 补丁

## 问题现象

| 场景 | 结果 |
|------|------|
| 人 @ 机器人 | ✅ 正常回复 |
| 机器人 @ 机器人 | ❌ 接收方无响应 |

## 根因：`_allow_group_message` 的 allowlist 策略

### 关键代码

`gateway/platforms/feishu.py:3604` — `_allow_group_message()`

```python
def _allow_group_message(self, sender_id: Any, chat_id: str = "") -> bool:
    sender_open_id = getattr(sender_id, "open_id", None)
    sender_user_id = getattr(sender_id, "user_id", None)
    sender_ids = {sender_open_id, sender_user_id} - {None}

    # admin 直接放行
    if sender_ids and self._admins and (sender_ids & self._admins):
        return True

    rule = self._group_rules.get(chat_id) if chat_id else None
    if rule:
        policy = rule.policy
        allowlist = rule.allowlist
    else:
        policy = self._group_policy          # 默认 "allowlist"
        allowlist = self._allowed_group_users  # 即 FEISHU_ALLOWED_USERS

    if policy == "allowlist":
        return bool(sender_ids and (sender_ids & allowlist))  # ← 这里！
```

### Bot-to-Bot 失败原因

| 发送者 | sender_id | 在 FEISHU_ALLOWED_USERS？ | policy=allowlist 结果 |
|--------|-----------|--------------------------|----------------------|
| 人类用户 | 人的 open_id | ✅ 在 | True → 回复 |
| bailong-hermes 发消息给 wk-hermes | `cli_a9408f9c74781cc8` | ❌ 不在 | **False → 丢弃** |

消息在第一道关卡 `_allow_group_message` 就被丢弃，根本到不了后面的 @mention 检查。

### 调用链

```
收到消息
  → _should_accept_group_message()
      → _allow_group_message(sender_id, chat_id)  ← 第一关
          → policy="allowlist" + sender_id 不在 allowlist → 返回 False（丢弃）
      → [后续 @mention 检查被跳过]
```

## 解决方案

### 方案 A：群策略改为 open（测试最快）

在接收方 bot 的 `config.yaml` 里加：

```yaml
group_rules:
  oc_b70407312481c83d1918c34f7e16a7f1:
    policy: open
  oc_629f6534bd95cc0730b791f8a1456397:
    policy: open
  oc_22e019265c6096916f5a78de44f3cdea:
    policy: open
```

然后重启：
```bash
systemctl --user restart hermes-gateway-[profile]
```

### 方案 B：在 FEISHU_ALLOWED_USERS 加入其他 bot

在 `.env` 中把其他 bot 的 ID 加进去：

```bash
# wk-hermes 的 .env，加上 bailong-hermes
FEISHU_ALLOWED_USERS="cli_a9408f9c74781cc8"
```

### 方案 C：全局默认 policy 改 open

在 `.env` 中：

```bash
FEISHU_GROUP_POLICY=open
```

## Bot app_id / open_id 速查

| Bot | profile | app_id (CLI) | open_id |
|-----|---------|-------------|---------|
| bailong-hermes | bailong | `cli_a9408f9c74781cc8` | `ou_043010649f6b148adcc493b68f8e0478` |
| wk-hermes | wukong | `cli_a966764c29781bc3` | （查 `.env` 中 FEISHU_BOT_OPEN_ID）|
| mao | （需查）| （需查）| （需查）|

```bash
# 查询自己（wk-hermes）的 open_id
grep -i "BOT_OPEN_ID\|FEISHU_BOT_OPEN_ID" ~/.hermes/profiles/wukong/.env
```

## 调试命令

### 实时日志

```bash
# wk-hermes
journalctl --user -u hermes-gateway-wukong -f

# bailong-hermes
journalctl --user -u hermes-gateway-bailong -f
```

### 过滤关键日志

```bash
journalctl --user -u hermes-gateway-wukong -f | grep -i "allow_group\|_should_accept\|drop\|reject"
```

### 测试：在群里发消息

让 bailong-hermes 在 `oc_22e019265c6096916f5a78de44f3cdea` 发一条 @wk-hermes 的消息，然后看 wk-hermes 日志：

```bash
# 应该看到：allow_group_message=True → 收到
# 如果看到：allow_group_message=False → 被丢弃
```

## openclaw vs Hermes

| 项目 | openclaw（已废弃） | Hermes（当前） |
|------|------------------|---------------|
| 根因 | `gate.js` requireMention 拒绝无@消息 | `_allow_group_message` allowlist 拒绝 bot sender_id |
| 修复位置 | `gate.js` 加 `senderIsBot` 判断 | `config.yaml` 改 policy 或加 bot ID 到 FEISHU_ALLOWED_USERS |
| 重启命令 | `systemctl --user restart openclaw-gateway` | `systemctl --user restart hermes-gateway-[profile]` |

openclaw 补丁存档在 `patch/gate-bot-to-bot.patch`，不再用于生产系统。

## 状态（2026-04-29）

- ✅ bailong-hermes：`at_only: false`，免@响应正常
- ⏳ wk-hermes：等待 wukong 修改配置
- ⏳ mao：等待确认 profile 位置和配置修改
