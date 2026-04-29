# 添加 Hermes Webhook 端点

> 为 bot-pollerd 在 Hermes feishu adapter 中添加 `/webhook/poll` 端点

## 目标

让 Hermes feishu adapter 接收来自 bot-pollerd 的 HTTP 轮询消息，实现 bot-to-bot 通信。

## 前置条件

- Hermes 版本 >= 1.x
- bot-pollerd 已安装并运行

## 实现步骤

### Step 1: 找到 feishu.py

```bash
find ~/.hermes/hermes-agent -name "feishu.py" 2>/dev/null
# 通常在: ~/.hermes/hermes-agent/gateway/platforms/feishu.py
```

### Step 2: 找到 Webhook 端点注册位置

搜索现有的 Webhook 端点（`@app.post` 或 `@app.get`）：

```bash
grep -n "@app\." ~/.hermes/hermes-agent/gateway/platforms/feishu.py | head -20
```

常见的端点注册位置：
- 在文件末尾（推荐）
- 在 `__init__` 方法中
- 在单独的 router 文件中

### Step 3: 添加端点

在 feishu.py 末尾添加：

```python
# =============================================================================
# bot-pollerd Webhook 端点
# 用于接收轮询服务转发的 bot @ bot 消息
# =============================================================================

@app.post("/webhook/poll")
async def webhook_poll(request: Request):
    """
    接收 bot-pollerd 转发过来的消息。

    请求格式（由 bot-pollerd/http_forwarder.py 发送）:
    {
        "message_id": "om_xxx",
        "chat_id": "oc_xxx",
        "sender_open_id": "ou_xxx",
        "sender_type": "bot",
        "sender_name": "bailong-hermes",
        "text": "@wk-hermes 你的模型是什么？",
        "mentioned_me": true,
        "is_free_at_message": false,
    }
    """
    try:
        payload = await request.json()
    except Exception:
        return {"status": "error", "message": "invalid json"}

    # 验证必填字段
    required_fields = ["message_id", "chat_id", "sender_open_id", "text"]
    for field in required_fields:
        if field not in payload:
            return {"status": "error", "message": f"missing field: {field}"}, 400

    # 转发给现有的消息处理器
    # 这里需要根据 Hermes 的内部结构调用合适的消息处理函数
    # 一种方式是通过 FastAPI 的事件系统：
    await _forward_to_message_handler(payload)

    return {"status": "ok"}
```

### Step 4: 实现 `_forward_to_message_handler`

具体实现取决于 Hermes 的内部架构。以下是几种可能的方式：

#### 方式 A：通过事件总线（推荐）

如果 Hermes 有事件总线：

```python
from hermes_agent.events import EventBus, MessageReceived

async def _forward_to_message_handler(payload: dict):
    event = MessageReceived(
        platform="feishu",
        chat_id=payload["chat_id"],
        sender_id=payload["sender_open_id"],
        sender_type=payload.get("sender_type", "bot"),
        text=payload["text"],
        message_id=payload["message_id"],
        metadata={
            "sender_name": payload.get("sender_name", ""),
            "mentioned_me": payload.get("mentioned_me", False),
            "is_free_at_message": payload.get("is_free_at_message", False),
        },
    )
    await EventBus.publish(event)
```

#### 方式 B：通过 FeishuAdapter 内部方法

找到 `FeishuAdapter` 处理消息的方法，直接调用：

```python
# 在 feishu.py 里找到 FeishuAdapter 实例的获取方式
_async def _forward_to_message_handler(payload: dict):
    adapter = _get_feishu_adapter_instance()
    # 构造一个类似 WebSocket 事件的结构
    event = {
        "schema": "im.message.receive_v1",
        "data": {
            "message_id": payload["message_id"],
            "chat_id": payload["chat_id"],
            "sender": {
                "sender_type": payload.get("sender_type", "bot"),
                "sender_id": {"open_id": payload["sender_open_id"]},
            },
            "body": {"content": json.dumps({"text": payload["text"]})},
            "mentions": [],
        },
    }
    await adapter._on_message_event(event)
```

#### 方式 C：最简实现（直接发到群里做测试）

如果上述方式都太复杂，先用最简实现验证端点是否工作：

```python
import logging
logger = logging.getLogger(__name__)

@app.post("/webhook/poll")
async def webhook_poll(request: Request):
    payload = await request.json()
    logger.info(f"[pollerd] Received: {payload.get('message_id')} from {payload.get('sender_open_id')}: {payload.get('text', '')[:50]}")
    # TODO: route to actual message handler
    return {"status": "ok"}
```

先验证这个端点能被 pollerd 调用，再实现完整的消息处理逻辑。

### Step 5: 重启 Hermes

```bash
systemctl --user restart hermes-agent@<profile>
journalctl --user -u hermes-agent@<profile> -f | grep -i "webhook"
```

### Step 6: 测试端点

```bash
curl -X POST http://127.0.0.1:18999/webhook/poll \
  -H "Content-Type: application/json" \
  -d '{"message_id":"om_test","chat_id":"oc_xxx","sender_open_id":"ou_xxx","sender_type":"bot","text":"test","mentioned_me":true}'
```

期望：返回 `{"status": "ok"}`

---

## 不改 Hermes 的替代方案

如果不想改 Hermes 代码，可以用 **Unix Socket** 方案：

1. Hermes 启动时监听 `/tmp/pollerd_<profile>.sock`
2. pollerd 连接 socket 发送 JSON 消息
3. Hermes 从 socket 读取并处理

这样 Hermes 完全不需要暴露 HTTP 端口。

**但这个方案需要给 Hermes 加一个 socket listener 启动参数**，同样要改 Hermes。

---

## 验证清单

- [ ] `/webhook/poll` 端点返回 200
- [ ] pollerd 日志显示 "Forward success"
- [ ] Hermes 收到消息后有处理日志
- [ ] bot 在群里回复了消息
- [ ] bot-to-bot @ 消息被正确处理（不是 self-loop）
