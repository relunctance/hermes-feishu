# Bot-to-Bot 轮询通信协议

> 详细度：细节到令人发指，可直接用于编码。

## 1. 背景与问题

### 1.1 Feishu WebSocket 的 bot @ bot 限制

Feishu 平台的 `im.message.receive_v1` WebSocket 事件订阅存在平台级过滤：

| 发送者类型 | @ 目标 bot | WebSocket 事件是否投递 |
|-----------|-----------|----------------------|
| 人类 | bot | ✅ 投递 |
| bot (bailong-hermes) | bot (wk-hermes) | **❌ 飞书过滤，不投递** |

**结论**：使用 WebSocket 事件的 bot 无法收到其他 bot @ 自己的消息事件。

### 1.2 解决方案：HTTP API 轮询

Feishu `GET /im/v1/messages` API（轮询模式）**没有 bot @ bot 过滤**。通过定期轮询群消息，可以捕获所有消息，包括 bot @ bot。

### 1.3 约束条件

- **不改 Hermes feishu adapter**：避免升级覆盖
- **独立进程**：bot-pollerd 作为 Sidecar 运行
- **免@ 模式**：支持免 @ 广播，也支持 @ 模式
- **支持多 bot**：mao / wk-hermes / bailong-hermes 均可接入

---

## 2. 系统架构

```
┌──────────────────────────────────────────────────────────┐
│                    Feishu 平台                          │
│                                                          │
│  bailong-hermes ──@mention──→ [群消息]                  │
│  wk-hermes      ───────────→ [群消息]                   │
│  mao            ───────────→ [群消息]                   │
└────────────────────────┬───────────────────────────────┘
                          │ 每3秒轮询
                          ▼
┌──────────────────────────────────────────────────────────┐
│              bot-pollerd (独立进程)                     │
│                                                          │
│  1. poller.py      轮询器，定时调用 Feishu API           │
│  2. message_parser.py  解析消息，检测是否 @ 本 bot      │
│  3. http_forwarder.py  HTTP 转发给 Hermes Webhook        │
│  4. config.py      配置文件加载                         │
│  5. main.py        入口，协调所有组件                    │
└────────────────────────┬───────────────────────────────┘
                          │ HTTP POST (收到 bot @ bot 时)
                          ▼
┌──────────────────────────────────────────────────────────┐
│           Hermes feishu adapter (不动)                  │
│                                                          │
│  /webhook/poll ──→ 解析消息 ──→ Agent 处理 ──→ 回复群   │
└──────────────────────────────────────────────────────────┘
```

---

## 3. 消息格式

### 3.1 群内消息结构（Feishu API 返回）

```python
{
    "message_id": "om_xxx",
    "chat_id": "oc_xxx",
    "sender": {
        "sender_type": "user" | "bot",
        "sender_id": {"open_id": "ou_xxx"},
        "tenant_key": "xxx"
    },
    "body": {"content": "..."},  # JSON 字符串
    "mentions": [{"key": "@_user_1", "id": {"open_id": "ou_yyy"}, "name": "wk-hermes"}],
    "create_time": "1700000000",
    "message_type": "text"
}
```

### 3.2 消息内容格式（bot @ bot 时）

bot 在群里发消息时，消息 body.content 是一个 JSON 字符串：

```json
{
    "text": "@wk-hermes 你的模型是什么？"
}
```

### 3.3 mentions 字段

当消息 @ 某个用户或 bot 时，`mentions` 数组包含被 @ 的对象：

```python
mentions = [
    {"key": "@_user_1", "id": {"open_id": "ou_811266eb548e3ab3ad06a76ec8a2e291"}, "name": "wk-hermes"}
]
```

### 3.4 免@ 模式的识别

免@ 模式的消息 **不包含 mentions 字段** 或 mentions 数组为空。

---

## 4. 核心模块设计

### 4.1 config.py — 配置管理

**配置文件**：`~/.hermes/profiles/<profile>/pollerd.yaml`

```yaml
# pollerd.yaml 示例
feishu:
  app_id: "cli_a9408f9c74781cc8"        # bailong-hermes 的 app_id
  app_secret: "${FEISHU_APP_SECRET}"     # 从环境变量读取
  bot_open_id: "ou_043010649f6b148adcc493b68f8e0478"  # 本 bot 的 open_id

hermes:
  host: "127.0.0.1"
  port: 18999                           # 本 bot 的 Webhook 端口

polling:
  interval_seconds: 3
  batch_size: 20                        # 每次最多处理的消息数
  chatrooms:
    - chat_id: "oc_b70407312481c83d1918c34f7e16a7f1"
      mode: "at_only"                    # at_only | mention_all |免@
      enabled: true
    - chat_id: "oc_629f6534bd95cc0730b791f8a1456397"
      mode: "at_only"
      enabled: true
    - chat_id: "oc_22e019265c6096916f5a78de44f3cdea"
      mode: "mention_all"
      enabled: true

# 免@ 模式白名单（谁发的免@消息要处理）
免@_whitelist:
  - open_id: "ou_043010649f6b148adcc493b68f8e0478"  # bailong-hermes
  - open_id: "ou_811266eb548e3ab3ad06a76ec8a2e291"  # wk-hermes
  - open_id: "ou_95664eced41bf683c09aa88287f72203"  # mao
```

**配置加载逻辑**：
1. 读取 `~/.hermes/profiles/<profile>/pollerd.yaml`
2. 环境变量替换：`${ENV_VAR}` → `os.environ[ENV_VAR]`
3. 验证必填字段

### 4.2 poller.py — 轮询器

**核心类**：`FeishuMessagePoller`

```python
class FeishuMessagePoller:
    def __init__(self, config: PollerConfig, http_forwarder: HttpForwarder):
        self.config = config
        self.forwarder = http_forwarder
        self._last_message_ids: dict[str, str] = {}  # chat_id -> last message_id

    def poll(self) -> list[ParsedMessage]:
        """单次轮询，返回该轮询周期内的新消息"""
        all_new_messages = []
        for room in config.chatrooms:
            if not room.enabled:
                continue
            messages = self._fetch_messages(room.chat_id)
            new_messages = self._filter_new(messages, room.chat_id)
            all_new_messages.extend(new_messages)
        return all_new_messages

    def _fetch_messages(self, chat_id: str) -> list[dict]:
        """
        调用 Feishu API:
        GET https://open.feishu.cn/open-apis/im/v1/messages?container_id_type=chat&container_id={chat_id}&sort_type=ByCreateTimeDesc
        """
        # 使用 bot access_token 调用
        # 返回最近 N 条消息（由 sort_type=ByCreateTimeDesc 保证是最新）
        pass

    def _filter_new(self, messages: list[dict], chat_id: str) -> list[dict]:
        """过滤出比上次已处理的更新的消息"""
        last_id = self._last_message_ids.get(chat_id)
        if not last_id:
            return messages[:config.polling.batch_size]
        # 按 message_id 找到断点，只取断点之后的新消息
        idx = next((i for i, m in enumerate(messages) if m["message_id"] == last_id), -1)
        return messages[:idx] if idx >= 0 else messages[:config.polling.batch_size]
```

**token 管理**：
- 调用 `POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal`
- 传入 `app_id` + `app_secret`
- token 有效期 2 小时，内部缓存，过期前自动刷新

### 4.3 message_parser.py — 消息解析

**核心类**：`MessageParser`

```python
@dataclass
class ParsedMessage:
    message_id: str
    chat_id: str
    sender_open_id: str
    sender_type: str  # "user" | "bot"
    sender_name: str
    text: str
    mentioned_me: bool  # 是否 @ 了本 bot
    is免@_message: bool  # 是否是免@ 模式消息
    raw: dict

class MessageParser:
    def __init__(self, my_open_id: str,免@_whitelist: list[str]):
        self.my_open_id = my_open_id
        self.免@_whitelist =免@_whitelist

    def parse(self, raw_message: dict, room_mode: str) -> ParsedMessage | None:
        """
        解析单条原始消息，返回 ParsedMessage 或 None（不需要处理）

        room_mode:
          - "at_only": 只处理 @ 本 bot 的消息
          - "mention_all": 处理所有 @ 了人的消息（人类 @ bot 或 bot @ bot）
          - "免@": 处理免@ 消息（无 mentions 且在白名单）
        """
        sender = raw_message.get("sender", {})
        sender_open_id = sender.get("sender_id", {}).get("open_id", "")
        sender_type = sender.get("sender_type", "")

        # 忽略自己发的消息（自己转发自己会死循环）
        if sender_open_id == self.my_open_id:
            return None

        # 解析 body.content（JSON 字符串）
        try:
            body = json.loads(raw_message.get("body", {}).get("content", "{}"))
            text = body.get("text", "")
        except json.JSONDecodeError:
            text = raw_message.get("body", {}).get("content", "")

        # 解析 mentions
        mentions = raw_message.get("mentions", [])
        mentioned_open_ids = [m.get("id", {}).get("open_id", "") for m in mentions]
        mentioned_me = self.my_open_id in mentioned_open_ids

        # 判断是否是免@消息（无 mentions 且发送者在白名单）
        is_免@ = (len(mentions) == 0) and (sender_open_id in self.免@_whitelist)

        # 根据 room_mode 决定是否处理
        should_handle = self._should_handle(room_mode, mentioned_me, is_免@, sender_type)
        if not should_handle:
            return None

        return ParsedMessage(
            message_id=raw_message["message_id"],
            chat_id=raw_message["chat_id"],
            sender_open_id=sender_open_id,
            sender_type=sender_type,
            sender_name=raw_message.get("sender", {}).get("sender_id", {}).get("open_id", ""),
            text=text,
            mentioned_me=mentioned_me,
            is免@_message=is_免@,
            raw=raw_message,
        )

    def _should_handle(self, mode: str, mentioned_me: bool, is_免@: bool, sender_type: str) -> bool:
        if mode == "at_only":
            return mentioned_me  # 必须 @ 本 bot
        elif mode == "mention_all":
            return mentioned_me  # @ 了任何人（本 bot 或其他人）
        elif mode == "免@":
            return is_免@  # 免@ 消息且在白名单
        return False
```

### 4.4 http_forwarder.py — HTTP 转发

**核心类**：`HttpForwarder`

```python
class HttpForwarder:
    def __init__(self, hermes_host: str, hermes_port: int):
        self.base_url = f"http://{hermes_host}:{hermes_port}"

    def forward(self, parsed: ParsedMessage) -> bool:
        """
        将解析后的消息 HTTP POST 给 Hermes Webhook

        Webhook 端点: POST /webhook/poll
        Body: {
            "message_id": "om_xxx",
            "chat_id": "oc_xxx",
            "sender_open_id": "ou_xxx",
            "sender_type": "bot",
            "text": "@wk-hermes 你的模型是什么？",
            "mentioned_me": true,
            "is_免@_message": false,
            "raw": {...}
        }
        """
        url = f"{self.base_url}/webhook/poll"
        payload = {
            "message_id": parsed.message_id,
            "chat_id": parsed.chat_id,
            "sender_open_id": parsed.sender_open_id,
            "sender_type": parsed.sender_type,
            "sender_name": parsed.sender_name,
            "text": parsed.text,
            "mentioned_me": parsed.mentioned_me,
            "is_免@_message": parsed.is免@_message,
        }
        try:
            resp = requests.post(url, json=payload, timeout=5)
            return resp.status_code == 200
        except requests.RequestException as e:
            logger.error(f"Forward failed: {e}")
            return False
```

### 4.5 main.py — 入口

```python
def main():
    config = load_config()
    forwarder = HttpForwarder(config.hermes.host, config.hermes.port)
    poller = FeishuMessagePoller(config, forwarder)
    parser = MessageParser(config.feishu.bot_open_id, config.免@_whitelist)

    logger.info(f"bot-pollerd 启动，bot_open_id={config.feishu.bot_open_id}")
    logger.info(f"监控群数量: {len(config.chatrooms)}")

    while True:
        try:
            raw_messages = poller.poll()
            for raw in raw_messages:
                # 找到这个消息所属的群的 mode
                room_mode = poller.get_room_mode(raw["chat_id"])
                parsed = parser.parse(raw, room_mode)
                if parsed:
                    success = forwarder.forward(parsed)
                    if success:
                        poller.mark_processed(parsed.message_id, parsed.chat_id)
                        logger.info(f"已转发: {parsed.message_id} from {parsed.sender_open_id}")
                    else:
                        logger.warning(f"转发失败: {parsed.message_id}")
        except Exception as e:
            logger.error(f"轮询异常: {e}")
        time.sleep(config.polling.interval_seconds)
```

### 4.6 Webhook 入口（Hermes 侧）

Hermes feishu adapter 需要新增一个端点 `POST /webhook/poll`：

```
请求:
POST /webhook/poll
Content-Type: application/json
{
    "message_id": "om_xxx",
    "chat_id": "oc_xxx",
    "sender_open_id": "ou_xxx",
    "sender_type": "bot",
    "text": "@wk-hermes 你的模型是什么？",
    "mentioned_me": true,
    "is_免@_message": false,
}

响应:
200 OK {"status": "ok"}
```

这个端点直接复用 Hermes 现有的消息处理流程，但额外设置 `sender_type=bot`，让 Hermes 知道这是 bot 发的消息。

---

## 5. 消息 ID 追踪（幂等性）

### 5.1 问题

轮询是"拉取最近 N 条消息"，同一个消息可能被多次处理（多轮轮询重复拿到）。

### 5.2 解决方案

每个 chat_id 维护 `last_processed_message_id`：

```
轮询返回: [msg_D, msg_C, msg_B, msg_A]  (最新→最旧)
last_processed = msg_B
过滤: [msg_D, msg_C]  (只处理比 last_processed 更新的)
处理完: last_processed = msg_D
```

重启后 `last_processed` 丢失，但可以用时间窗口过滤（消息 `create_time` > 5 分钟前的才处理）。

---

## 6. 消息模式详解

### 6.1 @ 模式（at_only / mention_all）

- bot @ bot：消息包含 `mentions` 数组，`parser.parse()` 返回 `mentioned_me=True`
- 人类 @ bot：同上，但 `sender_type="user"`
- 人类 @ 人类（免@ bot）：消息包含 `mentions` 但不包含本 bot，不处理

### 6.2 免@ 模式

**触发条件**：
1. `mentions` 数组为空（消息里没有 @ 任何人）
2. 发送者的 `open_id` 在 `免@_whitelist` 中

**示例**：
```
bailong-hermes（open_id=ou_043...）在免@群里发：
  "今天天气不错，大家各自工作"
  
解析结果:
  is_免@_message = True
  text = "今天天气不错，大家各自工作"
  mentioned_me = False
```

### 6.3 混合模式

一个群可以同时配置免@ + @ 模式，解析器根据消息同时满足哪个条件来决定是否处理。

---

## 7. 错误处理

### 7.1 Feishu API 错误

| 错误码 | 含义 | 处理 |
|--------|------|------|
| 99991663 | token 过期 | 自动刷新 token，重试 |
| 230013 | 频率限制 | 指数退避（2s → 4s → 8s → 16s → 32s） |
| 230001 | 机器人没有在群里 | 记录警告，跳过该群 |
| 其他 | 网络错误 | 记录警告，继续轮询 |

### 7.2 Hermes Webhook 错误

| 状态码 | 处理 |
|--------|------|
| 200 | 成功，标记已处理 |
| 4xx | 记录错误，不重试（消息格式错误） |
| 5xx | 重试 3 次，间隔 1s |

---

## 8. 日志规范

```
[2026-04-29 15:00:01] [INFO] bot-pollerd 启动，bot_open_id=ou_xxx
[2026-04-29 15:00:04] [INFO] 轮询完成，获取 3 条新消息
[2026-04-29 15:00:04] [INFO] 转发成功: om_xxx from ou_yyy (bot)
[2026-04-29 15:00:07] [INFO] 轮询完成，获取 0 条新消息
[2026-04-29 15:00:10] [WARN] Hermes Webhook 返回 500，重试第 1 次
[2026-04-29 15:00:11] [WARN] Hermes Webhook 返回 500，重试第 2 次
[2026-04-29 15:00:12] [ERROR] Hermes Webhook 重试失败: om_xxx
```

---

## 9. 部署架构

### 9.1 每个 bot 一个 pollerd 实例

```
bailong-hermes 进程: hermes-agent --profile bailong
bailong-pollerd 进程: python -m bot_pollerd --profile bailong

wk-hermes 进程: hermes-agent --profile wukong
wk-pollerd 进程: python -m bot_pollerd --profile wukong

mao 进程: hermes-agent --profile mao
mao-pollerd 进程: python -m bot_pollerd --profile mao
```

### 9.2 pollerd 作为 systemd 服务

```ini
[Unit]
Description=bot-pollerd for %p
After=network.target

[Service]
Type=simple
User=gql
WorkingDirectory=/home/gql/repos/hermes-feishu
ExecStart=/home/gql/.pyenv/shims/python -m bot_pollerd --profile %p
Restart=always
RestartSec=5
Environment=PATH=/home/gql/.pyenv/shims:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
```

服务名格式：`pollerd@<profile>`，例如 `pollerd@mao`。

---

## 10. Hermes Webhook 端点接入

### 10.1 不改 feishu_adapter 的方案

Hermes 的 Webhook 端点由 API server 提供。pollerd 转发消息时，直接调 Hermes 的**消息处理函数**（内部调用，不走 HTTP）。

```python
# 在 Hermes 进程内，导入消息处理函数
from hermes_agent.gateway.platforms.feishu import FeishuAdapter

async def handle_poll_message(payload: dict):
    """pollerd 通过内部函数调用 Hermes"""
    # 复用 FeishuAdapter._on_p2p_im_message_receive 的逻辑
    pass
```

**但这要求 pollerd 和 Hermes 在同一进程**，不符合"不改 Hermes"的原则。

### 10.2 HTTP Webhook 端点方案（推荐）

在 Hermes 的 HTTP server 新增一个端点：

```python
# Hermes API Server 新增路由
@app.post("/webhook/poll")
async def webhook_poll(request: Request):
    payload = await request.json()
    # 直接调用 feishu adapter 的消息处理
    await feishu_adapter.handle_poll_message(payload)
    return {"status": "ok"}
```

**但这要求改 Hermes 代码**，虽然改动很小。

### 10.3 Unix Socket 方案（最干净）

pollerd 通过 Unix socket 发消息给 Hermes，Hermes 监听 socket 并处理。

```
pollerd                  Hermes
   │                        │
   │  Unix Socket /tmp/pollerd.sock
   │ ──────────────────────→
   │                        │
```

**这是完全不改 Hermes 代码的方案**：
- Hermes 只需要监听一个 Unix socket 文件（启动参数指定）
- pollerd 连接 socket 发送 JSON 消息
- Hermes 解析后走原有的消息处理流程

**缺点**：需要给 Hermes 加一个 socket listener 启动参数。

### 10.4 实际选择

先用 **HTTP Webhook 端点**（方案 10.2），因为：
- 改动极小（只加一个 `@app.post` 端点）
- pollerd 不需要和 Hermes 同机部署
- 调试方便（HTTP 请求可抓包）

后续可以演进到 Unix Socket 方案。

---

## 11. 测试策略（TDD）

### 11.1 测试分层

| 测试文件 | 测试内容 |
|---------|---------|
| `test_message_parser.py` | 消息解析逻辑（不依赖网络） |
| `test_poller.py` | 轮询器消息过滤、last_id 追踪 |
| `test_http_forwarder.py` | HTTP 转发逻辑（mock Hermes） |
| `test_integration.py` | 完整流程（需要 Feishu API mock） |

### 11.2 Mock 策略

- **Feishu API**: 用 `responses` 库 mock HTTP 请求
- **Hermes Webhook**: 用 `responses` 库 mock POST 请求
- **配置加载**: 用临时文件 + yaml 加载

### 11.3 边界条件

- 自己发的消息要忽略（`sender_open_id == my_open_id`）
- 空 mentions 数组的免@消息识别
- 消息 ID 重复时的幂等处理
- Feishu token 过期刷新
- Hermes Webhook 超时和重试

---

## 12. 已知限制

1. **延迟**：轮询间隔 3 秒，最坏延迟 3 秒（WebSocket 是毫秒级）
2. **频率限制**：Feishu API 有 QPS 限制，多 bot 同时轮询需控制频率
3. **重启丢失状态**：last_processed_message_id 存在内存，重启后可能重复处理最近几条消息（窗口内）
4. **飞书 API 版本**：文档基于 2024 年 API，未来可能变化

---

## 13. 文件结构

```
hermes-feishu/
├── bot-pollerd/
│   ├── __init__.py
│   ├── main.py              # 入口
│   ├── poller.py           # 轮询器
│   ├── message_parser.py   # 消息解析
│   ├── http_forwarder.py   # HTTP 转发
│   ├── config.py           # 配置管理
│   ├── exceptions.py       # 自定义异常
│   ├── logger.py           # 日志配置
│   └── tests/
│       ├── __init__.py
│       ├── test_message_parser.py
│       ├── test_poller.py
│       └── test_http_forwarder.py
├── install.sh              # 一键安装脚本（交互式）
├── upgrade.sh              # 升级脚本
├── config/
│   └── pollerd.yaml.example  # 配置模板
├── docs/
│   ├── BOT_TO_BOT_PROTOCOL.md  # 本文档
│   ├── INSTALLATION.md        # 安装文档
│   └── DEBUGGING.md           # 调试指南
├── README.md
└── SKILL.md
```

---

## 14. 版本兼容性

| bot-pollerd 版本 | Hermes 版本 | 说明 |
|-----------------|-----------|------|
| v1.0.0 | >= 1.x | 初始版本，依赖 Hermes Webhook 端点 |

---

## 15. 升级建议

详见 `upgrade.sh` 脚本和 `docs/UPGRADE.md`。

核心升级步骤：
1. `git pull` 获取新版本
2. `python -m bot_pollerd --dry-run` 验证配置
3. `systemctl --user restart pollerd@<profile>` 重启服务
4. `journalctl --user -u pollerd@<profile> -f` 验证日志
