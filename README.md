# bot-pollerd — Feishu Bot-to-Bot 轮询服务

> 让 Hermes bot 与 bot 之间可以相互通信，绕过 Feishu WebSocket 的 bot @ bot 事件过滤限制。

## 问题

Feishu 的 `im.message.receive_v1` WebSocket 事件订阅存在**平台级过滤**：

| 发送者 | @ 目标 bot | WebSocket 收到？ |
|--------|-----------|-----------------|
| 人类 | bot | ✅ |
| bot | bot | **❌ 飞书不投递** |

bot-pollerd 通过**HTTP API 轮询**绕过这个限制。

## 架构

```
bailong-hermes ──@mention──→ [群消息]
wk-hermes      ───────────→ [群消息]    ←── 每3秒轮询
                              │
                         Feishu API
                              │
                    ┌─────────▼─────────┐
                    │   bot-pollerd     │
                    │  (独立进程)        │
                    │                   │
                    │  1. poller.py     │  ← 轮询群消息
                    │  2. message_parser│  ← 解析，检测 @ 或 free_at
                    │  3. http_forwarder│  ← 转发给 Hermes
                    └─────────┬─────────┘
                              │ HTTP POST
                              ▼
                    ┌─────────────────┐
                    │ Hermes feishu   │
                    │ /webhook/poll   │  ← 新增端点
                    └─────────────────┘
```

## 快速开始

### 第一步：运行安装向导

```bash
cd ~/repos/hermes-feishu
./install.sh --profile mao
```

安装向导会：
1. 检测 Python 依赖（requests, pyyaml）
2. 读取 Hermes profile 配置（自动填充 app_id / app_secret / bot_open_id）
3. 交互式配置监控的群和消息模式
4. 生成 `~/.hermes/profiles/<profile>/pollerd.yaml`
5. 生成 systemd service 文件

### 第二步：验证配置

```bash
python -m bot_pollerd --profile mao --dry-run
```

### 第三步：启动服务

```bash
systemctl --user start pollerd@mao
journalctl --user -u pollerd@mao -f
```

### 第四步：启用开机自启

```bash
systemctl --user enable pollerd@mao
```

---

## 消息模式

### at_only 模式（默认）

只处理 **@ 自己的消息**。

```
bailong @wk-hermes → wk-hermes 处理 ✓
人类 @wk-hermes   → wk-hermes 处理 ✓
bailong @张三      → wk-hermes 跳过 ✓
```

### mention_all 模式

处理 **@ 了任何人的消息**（包括 bot @ bot）。

```
bailong @wk-hermes → wk-hermes 处理 ✓
人类 @bailong      → wk-hermes 处理 ✓（@ 了人）
bailong @张三      → wk-hermes 处理 ✓（@ 了人）
```

### free_at 模式（免@）

处理**来自白名单 bot 的无 @ 消息**。用于"广播"场景——bot 发消息不需要 @任何人，其他白名单 bot 都会收到。

```
bailong 发: "今天天气不错，大家加油"
wk-hermes 收到 → 处理 ✓
mao        收到 → 处理 ✓
```

## 配置说明

### pollerd.yaml

```yaml
feishu:
  app_id: "${FEISHU_APP_ID}"       # 来自环境变量
  app_secret: "${FEISHU_APP_SECRET}"
  bot_open_id: "${FEISHU_BOT_OPEN_ID}"

hermes:
  host: "127.0.0.1"
  port: 18999

polling:
  interval_seconds: 3             # 轮询间隔，不要小于 2
  batch_size: 20

chatrooms:
  - chat_id: "oc_xxx"
    mode: "free_at"               # at_only | mention_all | free_at
    enabled: true

free_at_whitelist:
  - "ou_043010649f6b148adcc493b68f8e0478"  # bailong-hermes
  - "ou_811266eb548e3ab3ad06a76ec8a2e291"  # wk-hermes
  - "ou_95664eced41bf683c09aa88287f72203"  # mao
```

### 环境变量

推荐在 `~/.hermes/profiles/<profile>/.env` 中设置：

```
FEISHU_APP_ID=cli_a9408f9c74781cc8
FEISHU_APP_SECRET=your_secret_here
FEISHU_BOT_OPEN_ID=ou_043010649f6b148adcc493b68f8e0478
```

配置文件使用 `${FEISHU_APP_ID}` 语法读取环境变量。

## Hermes Webhook 端点

bot-pollerd 需要 Hermes 新增一个 HTTP 端点来接收轮询消息：

```
POST /webhook/poll
Content-Type: application/json

{
    "message_id": "om_xxx",
    "chat_id": "oc_xxx",
    "sender_open_id": "ou_xxx",
    "sender_type": "bot",
    "sender_name": "bailong-hermes",
    "text": "@wk-hermes 你的模型是什么？",
    "mentioned_me": true,
    "is_free_at_message": false
}
```

### 添加方法（不改 Hermes 原有代码）

在 `hermes-agent/gateway/platforms/feishu.py` 末尾添加：

```python
@app.post("/webhook/poll")
async def webhook_poll(request: Request):
    """Receive bot-to-bot messages from pollerd"""
    payload = await request.json()
    # 设置 sender_type 为 bot，让 Hermes 知道这是 bot 发的消息
    # 走 Hermes 现有的消息处理流程
    await _handle_poll_message(payload)
    return {"status": "ok"}
```

参考：`docs/ADD_WEBHOOK_ENDPOINT.md`

## 多 bot 部署

每个 bot 需要独立的 pollerd 实例：

```
pollerd@mao      → 监控 mao 收到的 bot @ bot 消息
pollerd@wukong   → 监控 wk-hermes 收到的 bot @ bot 消息
pollerd@bailong  → 监控 bailong-hermes 收到的 bot @ bot 消息
```

每个实例使用**不同的 app_id / app_secret / bot_open_id**，但**可以监控相同的群**。

## 文件结构

```
hermes-feishu/
├── bot-pollerd/
│   ├── __init__.py
│   ├── main.py              # 入口
│   ├── poller.py           # 轮询器
│   ├── message_parser.py   # 消息解析
│   ├── http_forwarder.py   # HTTP 转发
│   ├── config.py           # 配置管理
│   └── tests/
│       ├── test_message_parser.py
│       ├── test_config.py
│       └── test_http_forwarder.py
├── install.sh              # 一键安装脚本（交互式）
├── upgrade.sh             # 升级脚本
├── config/
│   └── pollerd.yaml.example
├── docs/
│   ├── BOT_TO_BOT_PROTOCOL.md   # 技术协议文档
│   ├── ADD_WEBHOOK_ENDPOINT.md  # Hermes Webhook 端点添加指南
│   └── DEBUGGING.md             # 调试指南
├── README.md
└── SKILL.md
```

## 故障排除

### pollerd 启动失败

```bash
python -m bot_pollerd --profile mao --dry-run
# 检查配置是否正确
```

### 消息没有被处理

1. 检查 bot 是否在群里：`journalctl --user -u pollerd@mao | grep "Skipping own"`
2. 检查免@白名单是否包含发送者
3. 检查群 mode 是否正确（at_only/mention_all/free_at）

### Hermes 没有收到消息

```bash
curl -X POST http://127.0.0.1:18999/webhook/poll \
  -H "Content-Type: application/json" \
  -d '{"message_id":"test","chat_id":"oc_xxx","sender_open_id":"ou_test","sender_type":"bot","text":"test","mentioned_me":true}'
```

### 重复处理消息

pollerd 用 last_processed_message_id 追踪已处理消息。重启后有 5 分钟时间窗口保护。

## 已知限制

1. **延迟**：轮询间隔 3 秒，最坏延迟 3 秒
2. **频率限制**：Feishu API 有 QPS 上限，多实例同时轮询需控制频率
3. **重启丢失状态**：last_processed_message_id 存在内存，重启后可能短暂重复处理

## 相关文档

- [BOT_TO_BOT_PROTOCOL.md](docs/BOT_TO_BOT_PROTOCOL.md) — 完整技术协议
- [ADD_WEBHOOK_ENDPOINT.md](docs/ADD_WEBHOOK_ENDPOINT.md) — Hermes 端点添加指南
- [DEBUGGING.md](docs/DEBUGGING.md) — 调试指南
- [SKILL.md](SKILL.md) — Hermes Skill 文档
