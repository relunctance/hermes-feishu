# SKILL: bot-pollerd 部署与调试

> Hermes bot-to-bot 通信轮询服务

## 触发条件

- 场景：需要 bot 与 bot 在群里相互通信，但飞书 WebSocket 事件不支持 bot @ bot
- 触发：`_feishu bot to bot communication_`, `_bot @ bot not working_`, `_免@ broadcast setup_`
- 同时查看 skill: `feishu-debug`

---

## 快速部署（单 bot）

### 1. 运行安装向导

```bash
cd ~/repos/hermes-feishu
./install.sh --profile <profile>
# 例如: ./install.sh --profile mao
```

安装向导交互流程：
1. 自动检测 Python 和依赖（requests, pyyaml）
2. 读取 Hermes profile 配置（app_id / app_secret / bot_open_id）
3. 交互输入群 ID 和模式
4. 生成 `~/.hermes/profiles/<profile>/pollerd.yaml`
5. 生成 systemd service 文件

### 2. 验证配置

```bash
python -m bot_pollerd --profile <profile> --dry-run
```

### 3. 启动服务

```bash
systemctl --user start pollerd@<profile>
# 例如: systemctl --user start pollerd@mao
```

### 4. 验证运行

```bash
journalctl --user -u pollerd@<profile> -f
# 或
ps aux | grep bot_pollerd | grep -v grep
```

### 5. 启用开机自启

```bash
systemctl --user enable pollerd@<profile>
```

---

## 部署多 bot

每个 bot 需要独立的 pollerd 实例：

```bash
./install.sh --profile mao      # 安装 mao 的 pollerd
./install.sh --profile wukong  # 安装 wk-hermes 的 pollerd
./install.sh --profile bailong # 安装 bailong-hermes 的 pollerd
```

每个实例使用**不同的配置文件**（`~/.hermes/profiles/<profile>/pollerd.yaml`），但**可以监控相同的群**。

---

## 关键配置说明

### pollerd.yaml 必填字段

```yaml
feishu:
  app_id: "${FEISHU_APP_ID}"       # 必须填写
  app_secret: "${FEISHU_APP_SECRET}"
  bot_open_id: "${FEISHU_BOT_OPEN_ID}"

chatrooms:
  - chat_id: "oc_xxx"              # 要监控的群 ID
    mode: "free_at"                # at_only | mention_all | free_at
    enabled: true
```

### 消息模式选择

| 模式 | 使用场景 | bot @ bot | 人类 @ bot | 免@ |
|------|---------|-----------|------------|-----|
| `at_only` | 传统 @ 模式 | ❌ | ✅ | ❌ |
| `mention_all` | 需要 bot @ bot 响应 | ✅ | ✅ | ❌ |
| `free_at` | 广播模式，无需 @ | ✅ | ❌ | ✅ |

**推荐**：群设为 `free_at`，所有白名单 bot 发的消息其他 bot 都处理。

### 免@白名单

```yaml
free_at_whitelist:
  - "ou_043010649f6b148adcc493b68f8e0478"  # bailong-hermes
  - "ou_811266eb548e3ab3ad06a76ec8a2e291"  # wk-hermes
  - "ou_95664eced41bf683c09aa88287f72203"  # mao
```

---

## Hermes Webhook 端点（必须）

bot-pollerd 需要 Hermes 暴露一个 `/webhook/poll` 端点来接收轮询消息。

**添加方法**：在 `hermes-agent/gateway/platforms/feishu.py` 末尾添加：

```python
@app.post("/webhook/poll")
async def webhook_poll(request: Request):
    """Receive bot-to-bot messages from pollerd"""
    from .feishu import FeishuAdapter
    adapter = get_feishu_adapter_instance()
    payload = await request.json()
    await adapter.handle_poll_message(payload)
    return {"status": "ok"}
```

详细步骤见：`docs/ADD_WEBHOOK_ENDPOINT.md`

---

## 调试步骤

### Step 1: 检查 pollerd 是否运行

```bash
ps aux | grep bot_pollerd | grep -v grep
systemctl --user status pollerd@<profile>
```

### Step 2: 查看实时日志

```bash
journalctl --user -u pollerd@<profile> -f --since "5 minutes ago"
```

常见日志：
- `[INFO] Skipping own message` → 正常，跳过自己发的
- `[INFO] Forward success` → 消息已转发
- `[WARN] Rate limited by Feishu` → API 频率限制，稍后重试
- `[ERROR] Forward failed after 3 attempts` → Hermes Webhook 不可达

### Step 3: 测试 Hermes Webhook

```bash
curl -X POST http://127.0.0.1:18999/webhook/poll \
  -H "Content-Type: application/json" \
  -d '{
    "message_id": "om_test",
    "chat_id": "oc_xxx",
    "sender_open_id": "ou_xxx",
    "sender_type": "bot",
    "sender_name": "test-bot",
    "text": "@wk-hermes hello",
    "mentioned_me": true,
    "is_free_at_message": false
  }'
```

期望返回：`{"status": "ok"}`

### Step 4: 测试轮询（dry-run）

```bash
python -m bot_pollerd --profile <profile> --dry-run
```

### Step 5: 手动触发轮询（在线调试）

在另一个终端：

```bash
watch -n 3 'curl -s http://127.0.0.1:18999/health || echo "Hermes not responding"'
```

### Step 6: 验证消息解析

```python
from bot_pollerd.message_parser import MessageParser

parser = MessageParser(
    my_open_id="ou_xxx",
    free_at_whitelist=["ou_yyy", "ou_zzz"]
)
# 测试 free_at 消息
raw = {
    "message_id": "om_test",
    "chat_id": "oc_group",
    "sender": {"sender_type": "bot", "sender_id": {"open_id": "ou_yyy"}},
    "body": {"content": '{"text": "hello"}'},
    "mentions": [],
}
result = parser.parse(raw, room_mode="free_at")
print(result)  # 应该是 ParsedMessage 或 None
```

---

## 常见问题

### Q: pollerd 启动失败 "Config not found"

```bash
# 检查配置文件是否存在
ls ~/.hermes/profiles/<profile>/pollerd.yaml

# 如果不存在，重新运行安装向导
./install.sh --profile <profile>
```

### Q: "Hermes Webhook 返回 500"

Hermes 的 `/webhook/poll` 端点未实现或出错。检查 Hermes 日志：

```bash
journalctl --user -u hermes-agent@<profile> -f
```

### Q: bot 没有收到其他 bot 的消息

1. 确认 bot 在群里（飞书 UI 检查）
2. 确认发送者在免@白名单中
3. 确认群的 mode 设置正确（free_at / mention_all）
4. 确认 pollerd 进程的 `bot_open_id` 是**本 bot** 的，不是对方 bot 的

### Q: 消息被重复处理

pollerd 用 last_processed_message_id 防止重复。如果重复，可能是 Hermes 处理失败导致没有 mark_processed。检查 Hermes Webhook 是否返回 200。

### Q: 免@消息没有被识别

检查消息的 `mentions` 字段。如果消息里包含了 @任何人，即使在 free_at 模式也会被忽略（因为 `is_free_at_message` 要求 mentions 为空）。

---

## 升级

```bash
cd ~/repos/hermes-feishu
git pull

# 验证新版本
python -m bot_pollerd --profile <profile> --dry-run

# 重启服务
systemctl --user restart pollerd@<profile>

# 检查日志
journalctl --user -u pollerd@<profile> -f
```

---

## 文件路径

| 文件 | 路径 |
|------|------|
| pollerd 源码 | `~/repos/hermes-feishu/bot-pollerd/` |
| 配置文件 | `~/.hermes/profiles/<profile>/pollerd.yaml` |
| systemd service | `~/.config/systemd/user/pollerd@.service` |
| 日志 | `journalctl --user -u pollerd@<profile>` |
| Hermes feishu.py | `~/.hermes/hermes-agent/gateway/platforms/feishu.py` |

---

## 安全注意

1. **app_secret 不要写在命令里**，使用环境变量 `${FEISHU_APP_SECRET}`
2. **port 不要暴露到公网**，默认 127.0.0.1:18999 是本地监听
3. **白名单要精确**，不要把不受信任的 open_id 加入免@白名单
