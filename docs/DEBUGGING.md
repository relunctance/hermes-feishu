# Bot-to-Bot 免@广播模式调试

## 问题现象

- ✅ 人 @ 机器人 → 正常回复
- ❌ 机器人 @ 机器人 → 接收方无响应

## 根因定位

### 消息流向

```
飞书服务器 → Hermes Gateway (WebSocket) → feishu.py → _should_accept_group_message()
```

### 关键函数：`_allow_group_message`

位于 `gateway/platforms/feishu.py:3604`

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
        policy = self._group_policy  # 默认 "allowlist"
        allowlist = self._allowed_group_users  # 即 FEISHU_ALLOWED_USERS

    # policy="allowlist" 时，检查 sender_id 是否在 allowlist 中
    if policy == "allowlist":
        return bool(sender_ids and (sender_ids & allowlist))
```

### Bot-to-Bot 失败根因

| 组件 | sender_id | 在 FEISHU_ALLOWED_USERS？ |
|------|-----------|---------------------------|
| 人类用户 | 人的 open_id | ✅ 在 |
| wk-hermes | `cli_a966764c29781bc3` | ❌ 不在 |
| bailong-hermes | `cli_a9408f9c74781cc8` | ❌ 不在 |

当 `policy="allowlist"` 时，`_allow_group_message` 返回 `False`，消息被丢弃。

### `_should_accept_group_message` 调用链

```
收到的消息
  → _allow_group_message(sender_id, chat_id)  ← 第一道关卡
      → policy="allowlist" + sender_id 不在 allowlist → 返回 False（丢弃）
      → policy="open" → 返回 True（放行）
  → _should_accept_group_message() 继续检查 @mention
```

## 解决方案

### 方案 A：群策略改为 open（推荐测试用）

在 wk-hermes 的 `config.yaml` 中添加：

```yaml
group_rules:
  oc_b70407312481c83d1918c34f7e16a7f1:
    policy: open
  oc_629f6534bd95cc0730b791f8a1456397:
    policy: open
  oc_22e019265c6096916f5a78de44f3cdea:
    policy: open
```

### 方案 B：在 FEISHU_ALLOWED_USERS 中加入其他 bot 的 ID

| Bot | app_id / open_id |
|-----|-----------------|
| bailong-hermes | `cli_a9408f9c74781cc8` |
| wk-hermes | `cli_a966764c29781bc3` |

在 wk-hermes 的 `.env` 中：

```bash
FEISHU_ALLOWED_USERS="ou_xxxxxxxx(人类A),cli_a9408f9c74781cc8(另一个bot)"
```

## 调试命令

### 查看 wk-hermes 收到消息时的日志

```bash
# 查看实时日志
journalctl --user -u hermes-gateway-wukong -f

# 过滤关键词
journalctl --user -u hermes-gateway-wukong -f | grep -i "allow_group\|_should_accept\|drop\|reject"
```

### 验证 bot 发送的消息是否被丢

在群 `oc_22e019265c6096916f5a78de44f3cdea` 中，让 bailong-hermes @wk-hermes，然后看 wk-hermes 的日志：

```bash
journalctl --user -u hermes-gateway-wukong -f | grep -i "oc_22e019265c6096916f5a78de44f3cdea"
```

如果看到 `[DEBUG] Group ...: allow_group_message=False` → 消息被丢弃。

## Bot app_id 速查

| Bot 名称 | profile | app_id (CLI) | open_id |
|----------|---------|--------------|---------|
| bailong-hermes | bailong | `cli_a9408f9c74781cc8` | `ou_043010649f6b148adcc493b68f8e0478` |
| wk-hermes | wukong | `cli_a966764c29781bc3` | （需查）|
| mao | （需查）| （需查）| （需查）|

获取自己的 open_id：
```bash
grep -i "FEISHU_BOT_OPEN_ID\|BOT_OPEN_ID" ~/.hermes/profiles/wukong/.env
```

## 已知 bot 的 app_id

```
bailong-hermes:  cli_a9408f9c74781cc8
wk-hermes:       cli_a966764c29781bc3
```

## openclaw 历史（已废弃）

openclaw 是旧版 gateway（已卸载）。相关补丁保存在：
- `patch/gate-bot-to-bot.patch`

openclaw 的 bot-to-bot 修复机制是在 `gate.js` 加 `senderIsBot` 判断，绕过高亮的 `requireMention`。但 Hermes feishu.py 的根因不同——是 `_allow_group_message` 的 allowlist 策略。
