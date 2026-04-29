#!/usr/bin/env bash
# =============================================================================
# bot-pollerd 一键安装脚本
# 用法: ./install.sh [--profile <name>]
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLERD_DIR="$REPO_DIR/bot-pollerd"
SCRIPT_VERSION="1.0.0"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ----------------------------------------------------------------------------
# 解析参数
# ----------------------------------------------------------------------------
PROFILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#*=}"
            shift
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# 如果没指定 profile，尝试自动检测
if [[ -z "$PROFILE" ]]; then
    # 查找已有的 hermes profile
    PROFILES_DIR="$HOME/.hermes/profiles"
    if [[ -d "$PROFILES_DIR" ]]; then
        AVAILABLE=$(ls "$PROFILES_DIR" 2>/dev/null | grep -v '.home$' | tr '\n' ' ')
        if [[ -n "$AVAILABLE" ]]; then
            echo "检测到以下 Hermes profile:"
            echo "  $AVAILABLE"
            read -r -p "请选择要安装的 profile 名称: " PROFILE
        fi
    fi
    if [[ -z "$PROFILE" ]]; then
        read -r -p "请输入要安装的 profile 名称（如 mao, bailong, wukong）: " PROFILE
    fi
fi

[[ -z "$PROFILE" ]] && error "profile 不能为空"

PROFILE_DIR="$HOME/.hermes/profiles/$PROFILE"
POLLERD_CONFIG="$PROFILE_DIR/pollerd.yaml"
POLLERD_SERVICE="$HOME/.config/systemd/user/pollerd@.service"

info "安装 bot-pollerd for profile: $PROFILE"
info "Profile 目录: $PROFILE_DIR"

# ----------------------------------------------------------------------------
# Step 1: 检测依赖
# ----------------------------------------------------------------------------
info "Step 1: 检测依赖..."

# Python
if command -v python3 &>/dev/null; then
    PYTHON_CMD="python3"
elif command -v python &>/dev/null; then
    PYTHON_CMD="python"
else
    error "未找到 Python，请先安装 Python 3.8+"
fi
PYTHON_VERSION=$($PYTHON_CMD -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
info "  Python: $PYTHON_VERSION ($PYTHON_CMD)"

# requests 库
if $PYTHON_CMD -c "import requests" 2>/dev/null; then
    info "  requests: OK"
else
    warn "  requests 未安装，正在安装..."
    $PYTHON_CMD -m pip install requests pyyaml -q || error "安装 requests 失败"
fi

# yaml 库
if $PYTHON_CMD -c "import yaml" 2>/dev/null; then
    info "  pyyaml: OK"
else
    warn "  pyyaml 未安装，正在安装..."
    $PYTHON_CMD -m pip install pyyaml -q || error "安装 pyyaml 失败"
fi

# ----------------------------------------------------------------------------
# Step 2: 检测 Hermes profile 配置
# ----------------------------------------------------------------------------
info "Step 2: 检查 Hermes profile..."

if [[ ! -d "$PROFILE_DIR" ]]; then
    warn "Profile 目录不存在: $PROFILE_DIR"
    read -r -p "是否创建？[y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || error "安装中止"
    mkdir -p "$PROFILE_DIR"
    success "已创建: $PROFILE_DIR"
else
    success "Profile 目录: $PROFILE_DIR"
fi

# 读取 Hermes .env（如果存在）
HERMES_ENV="$PROFILE_DIR/.env"
HERMES_CONFIG="$PROFILE_DIR/config.yaml"

# ----------------------------------------------------------------------------
# Step 3: 读取当前 Hermes 配置（用于填充 bot-pollerd 配置）
# ----------------------------------------------------------------------------
info "Step 3: 读取 Hermes 配置..."

extract_env() {
    local key="$1"
    local file="$2"
    grep "^${key}=" "$file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo ""
}

FEISHU_APP_ID=""
FEISHU_APP_SECRET=""
FEISHU_BOT_OPEN_ID=""
HERMES_PORT="18999"

if [[ -f "$HERMES_ENV" ]]; then
    info "  读取 .env..."
    FEISHU_APP_ID=$(extract_env "FEISHU_APP_ID" "$HERMES_ENV")
    FEISHU_APP_SECRET=$(extract_env "FEISHU_APP_SECRET" "$HERMES_ENV")
    FEISHU_BOT_OPEN_ID=$(extract_env "FEISHU_BOT_OPEN_ID" "$HERMES_ENV")
    FEISHU_APP_SECRET_SOURCE=".env"
fi

if [[ -f "$HERMES_CONFIG" ]]; then
    info "  检查 config.yaml..."
    # 尝试从 config.yaml 读取（某些 Hermes 配置格式）
    BOT_OPEN_ID_YAML=$(grep -E "^\s*bot_open_id:" "$HERMES_CONFIG" 2>/dev/null | head -1 | awk '{print $2}' || echo "")
    if [[ -n "$BOT_OPEN_ID_YAML" && -z "$FEISHU_BOT_OPEN_ID" ]]; then
        FEISHU_BOT_OPEN_ID="$BOT_OPEN_ID_YAML"
    fi
fi

# ----------------------------------------------------------------------------
# Step 4: 交互式配置
# ----------------------------------------------------------------------------
info "Step 4: 交互式配置..."

echo ""
echo "=============================================="
echo "  bot-pollerd 配置向导"
echo "=============================================="
echo ""

# Feishu App ID
if [[ -z "$FEISHU_APP_ID" ]]; then
    read -r -p "Feishu App ID (cli_xxx): " FEISHU_APP_ID
else
    echo -n "Feishu App ID [${FEISHU_APP_ID}]: "
    read -r tmp; [[ -n "$tmp" ]] && FEISHU_APP_ID="$tmp"
fi

# Feishu App Secret
if [[ -z "$FEISHU_APP_SECRET" ]]; then
    read -r -p "Feishu App Secret: " FEISHU_APP_SECRET
else
    echo -n "Feishu App Secret [已设置]: "
    read -r tmp; [[ -n "$tmp" ]] && FEISHU_APP_SECRET="$tmp"
fi

# Bot Open ID
if [[ -z "$FEISHU_BOT_OPEN_ID" ]]; then
    read -r -p "Bot Open ID (ou_xxx): " FEISHU_BOT_OPEN_ID
else
    echo -n "Bot Open ID [${FEISHU_BOT_OPEN_ID}]: "
    read -r tmp; [[ -n "$tmp" ]] && FEISHU_BOT_OPEN_ID="$tmp"
fi

# Hermes Webhook Port
echo -n "Hermes Webhook Port [${HERMES_PORT}]: "
read -r tmp; [[ -n "$tmp" ]] && HERMES_PORT="$tmp"

# ----------------------------------------------------------------------------
# Step 5: 群配置
# ----------------------------------------------------------------------------
info "Step 5: 配置监控群..."

echo ""
echo "支持的群模式:"
echo "  1) at_only     - 只处理 @ 本 bot 的消息"
echo "  2) mention_all - 处理 @ 了任何人的消息（支持 bot @ bot）"
echo "  3) free_at     - 免@模式（白名单 bot 发来的无 @ 消息）"
echo ""

# 预设群 ID
declare -a CHAT_IDS
declare -a CHAT_MODES

# 尝试从 Hermes 配置读取已知群 ID
KNOWN_CHATS=(
    "oc_b70407312481c83d1918c34f7e16a7f1:西游团队群"
    "oc_629f6534bd95cc0730b791f8a1456397:群2"
    "oc_22e019265c6096916f5a78de44f3cdea:群3"
)

for chat_info in "${KNOWN_CHATS[@]}"; do
    CHAT_ID="${chat_info%%:*}"
    CHAT_NAME="${chat_info#*:}"
    echo "检测到已知群:"
    echo "  $CHAT_NAME: $CHAT_ID"
    read -r -p "  是否监控此群？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "  选择模式 (1=at_only, 2=mention_all, 3=free_at) [3]: "
        read -r mode_num
        case "${mode_num:-3}" in
            1) MODE="at_only" ;;
            2) MODE="mention_all" ;;
            3) MODE="free_at" ;;
            *) MODE="free_at" ;;
        esac
        CHAT_IDS+=("$CHAT_ID")
        CHAT_MODES+=("$MODE")
        success "已添加: $CHAT_NAME ($MODE)"
    fi
done

# 添加更多群
echo ""
read -r -p "是否添加更多群？[y/N]: " confirm
while [[ "$confirm" =~ ^[Yy]$ ]]; do
    read -r -p "  群 ID (oc_xxx): " NEW_CHAT_ID
    read -r -p "  模式 (1=at_only, 2=mention_all, 3=free_at) [3]: " mode_num
    case "${mode_num:-3}" in
        1) MODE="at_only" ;;
        2) MODE="mention_all" ;;
        3) MODE="free_at" ;;
        *) MODE="free_at" ;;
    esac
    CHAT_IDS+=("$NEW_CHAT_ID")
    CHAT_MODES+=("$MODE")
    success "已添加: $NEW_CHAT_ID ($MODE)"
    read -r -p "继续添加？[y/N]: " confirm
done

if [[ ${#CHAT_IDS[@]} -eq 0 ]]; then
    warn "未配置任何群，安装中止"
    exit 1
fi

# ----------------------------------------------------------------------------
# Step 6: 免@白名单
# ----------------------------------------------------------------------------
info "Step 6: 配置免@白名单..."

echo ""
echo "免@白名单 - 哪些 bot 的消息可以在 free_at 模式被处理:"
echo "（输入 open_id，多个用逗号分隔，直接回车使用默认值）"
echo ""
echo "已知 bot open_id:"
echo "  bailong-hermes: ou_043010649f6b148adcc493b68f8e0478"
echo "  wk-hermes:      ou_811266eb548e3ab3ad06a76ec8a2e291"
echo "  mao:            ou_95664eced41bf683c09aa88287f72203"
echo ""
read -r -p "白名单 [默认: 以上三个]: " WHITELIST_INPUT

DEFAULT_WHITELIST="ou_043010649f6b148adcc493b68f8e0478,ou_811266eb548e3ab3ad06a76ec8a2e291,ou_95664eced41bf683c09aa88287f72203"
WHITELIST="${WHITELIST_INPUT:-$DEFAULT_WHITELIST}"

# ----------------------------------------------------------------------------
# Step 7: 更新 Hermes .env（注入 Webhook 端口）
# ----------------------------------------------------------------------------
info "Step 7: 更新 Hermes 配置..."

if [[ -f "$HERMES_ENV" ]]; then
    # 检查是否已有 POLLERD_WEBHOOK_PORT
    if ! grep -q "POLLERD_WEBHOOK_PORT" "$HERMES_ENV" 2>/dev/null; then
        echo "POLLERD_WEBHOOK_PORT=$HERMES_PORT" >> "$HERMES_ENV"
        info "  已添加 POLLERD_WEBHOOK_PORT=$HERMES_PORT 到 .env"
    else
        info "  POLLERD_WEBHOOK_PORT 已存在"
    fi
    # 更新 FEISHU_BOT_OPEN_ID
    if [[ -n "$FEISHU_BOT_OPEN_ID" ]] && ! grep -q "FEISHU_BOT_OPEN_ID" "$HERMES_ENV" 2>/dev/null; then
        echo "FEISHU_BOT_OPEN_ID=$FEISHU_BOT_OPEN_ID" >> "$HERMES_ENV"
        info "  已添加 FEISHU_BOT_OPEN_ID 到 .env"
    fi
else
    warn "  .env 不存在，跳过"
fi

# ----------------------------------------------------------------------------
# Step 8: 生成 pollerd.yaml
# ----------------------------------------------------------------------------
info "Step 8: 生成 pollerd.yaml..."

# 构建 chatrooms YAML 片段
CHATROOMS_YAML=""
for i in "${!CHAT_IDS[@]}"; do
    CHATROOMS_YAML+="  - chat_id: \"${CHAT_IDS[$i]}\"\n    mode: \"${CHAT_MODES[$i]}\"\n    enabled: true\n"
done

# 构建 whitelist YAML
IFS=',' read -ra WL_ARRAY <<< "$WHITELIST"
WHITELIST_YAML=""
for open_id in "${WL_ARRAY[@]}"; do
    WHITELIST_YAML+="  - \"${open_id}\"\n"
done

cat > "$POLLERD_CONFIG" << EOF
# =============================================================================
# bot-pollerd 配置文件
# 由 install.sh 自动生成
# profile: $PROFILE
# =============================================================================

feishu:
  app_id: "${FEISHU_APP_ID}"
  app_secret: "${FEISHU_APP_SECRET}"
  bot_open_id: "${FEISHU_BOT_OPEN_ID}"

hermes:
  host: "127.0.0.1"
  port: ${HERMES_PORT}

polling:
  interval_seconds: 3
  batch_size: 20

chatrooms:
${CHATROOMS_YAML}
free_at_whitelist:
${WHITELIST_YAML}
EOF

success "配置文件已写入: $POLLERD_CONFIG"

# ----------------------------------------------------------------------------
# Step 9: 生成 systemd service 文件
# ----------------------------------------------------------------------------
info "Step 9: 生成 systemd service..."

mkdir -p "$(dirname "$POLLERD_SERVICE")"

# 检测 Python 路径
PYTHON_PATH=$(command -v $PYTHON_CMD)

cat > "$POLLERD_SERVICE" << EOF
# =============================================================================
# bot-pollerd systemd service for profile: $PROFILE
# =============================================================================
[Unit]
Description=bot-pollerd for %p
After=network.target
PartOf=hermes-agent@%p.service

[Service]
Type=simple
User=gql
WorkingDirectory=${POLLERD_DIR}
ExecStart=${PYTHON_PATH} -m bot_pollerd --profile %p
Restart=always
RestartSec=5
Environment="PYTHONPATH=${POLLERD_DIR}"
Environment="PATH=${PATH}"

[Install]
WantedBy=multi-user.target
EOF

success "Service 文件已写入: $POLLERD_SERVICE"

# ----------------------------------------------------------------------------
# Step 10: 安装 Python 模块
# ----------------------------------------------------------------------------
info "Step 10: 安装 bot-pollerd 模块..."

# 在 profile 目录创建软链接或直接用 PYTHONPATH
mkdir -p "$PROFILE_DIR/modules"
ln -sf "$POLLERD_DIR" "$PROFILE_DIR/modules/bot_pollerd" 2>/dev/null || true

success "模块链接已创建: $PROFILE_DIR/modules/bot_pollerd -> $POLLERD_DIR"

# ----------------------------------------------------------------------------
# Step 11: 重载 systemd
# ----------------------------------------------------------------------------
info "Step 11: 重载 systemd..."
if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload 2>/dev/null || true
    success "systemd 已重载"
else
    warn "systemctl 不可用，跳过"
fi

# ----------------------------------------------------------------------------
# 完成
# ----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  安装完成!"
echo "=============================================="
echo ""
echo "下一步操作:"
echo ""
echo "  1. 验证配置:"
echo "     $PYTHON_CMD -m bot_pollerd --profile $PROFILE --dry-run"
echo ""
echo "  2. 启动服务:"
echo "     systemctl --user start pollerd@$PROFILE"
echo ""
echo "  3. 查看日志:"
echo "     journalctl --user -u pollerd@$PROFILE -f"
echo ""
echo "  4. 启用开机自启:"
echo "     systemctl --user enable pollerd@$PROFILE"
echo ""
echo "配置文件: $POLLERD_CONFIG"
echo "Service: $POLLERD_SERVICE"
echo ""
