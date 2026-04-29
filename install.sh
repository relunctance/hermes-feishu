#!/usr/bin/env bash
# =============================================================================
# bot-pollerd 一键安装脚本
# 用法: ./install.sh [--profile <name>]
# =============================================================================
set -eo pipefail

# 预先固定 fd 3（防止管道输入时 stdin 被 read 意外消耗）
# 所有需要独占 fd 的操作（读文件等）放在 Step 4，不会影响 stdin
exec 3< /dev/null

# 真实 home 目录（$HOME 会被 profile 环境覆盖）
REAL_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLERD_DIR="$REPO_DIR/bot-pollerd"
SCRIPT_VERSION="1.2.0"

# 关联数组（必须在 set -u 关闭后声明）
declare -A CHAT_MODE_PREVIOUS

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# -----------------------------------------------------------------------------
# 解析参数
# -----------------------------------------------------------------------------
PROFILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)
            PROFILE="$2"; shift 2 ;;
        --profile=*)
            PROFILE="${1#*=}"; shift ;;
        *)
            error "Unknown option: $1" ;;
    esac
done

# -----------------------------------------------------------------------------
# 自动检测 Hermes profile
# -----------------------------------------------------------------------------
if [[ -z "$PROFILE" ]]; then
    PROFILES_DIR="$REAL_HOME/.hermes/profiles"
    if [[ -d "$PROFILES_DIR" ]]; then
        AVAILABLE=$(ls "$PROFILES_DIR" 2>/dev/null | grep -v '.home$' | tr '\n' ' ')
        if [[ -n "$AVAILABLE" ]]; then
            echo "检测到以下 Hermes profile:"
            echo "  $AVAILABLE"
            if [[ -f "$REAL_HOME/.hermes/.env" ]]; then
                echo "  (主 Hermes: mao - 全局配置)"
            fi
            read -r -p "请选择要安装的 profile 名称: " PROFILE
        fi
    fi
    [[ -z "$PROFILE" ]] && read -r -p "请输入要安装的 profile 名称（如 mao, bailong, wukong）: " PROFILE
fi
[[ -z "$PROFILE" ]] && error "profile 不能为空"

# -----------------------------------------------------------------------------
# 检测是否为 "主 Hermes" (mao) — 没有 profiles/mao/ 目录
# -----------------------------------------------------------------------------
HERMES_BASE="$REAL_HOME/.hermes"
PROFILE_DIR="$HERMES_BASE/profiles/$PROFILE"
POLLERD_CONFIG_FILE="$PROFILE_DIR/pollerd.yaml"

IS_MAIN_HERMES=false
if [[ ! -d "$PROFILE_DIR" ]]; then
    if [[ -f "$HERMES_BASE/.env" ]] || [[ -f "$HERMES_BASE/config.yaml" ]]; then
        IS_MAIN_HERMES=true
        info "检测为【主 Hermes】(无独立 profile 目录，使用全局配置）"
        PROFILE_DIR="$HERMES_BASE"
        POLLERD_CONFIG_FILE="$HERMES_BASE/pollerd.yaml"
    fi
fi

info "安装 bot-pollerd for profile: $PROFILE"
info "配置目录: $PROFILE_DIR"

# -----------------------------------------------------------------------------
# Step 1: 检测依赖
# -----------------------------------------------------------------------------
info "Step 1: 检测依赖..."

if command -v python3 &>/dev/null; then
    PYTHON_CMD="python3"
elif command -v python &>/dev/null; then
    PYTHON_CMD="python"
else
    error "未找到 Python，请先安装 Python 3.8+"
fi
PYTHON_VERSION=$($PYTHON_CMD -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
info "  Python: $PYTHON_VERSION ($PYTHON_CMD)"

for lib in requests yaml; do
    if $PYTHON_CMD -c "import $lib" 2>/dev/null; then
        info "  $lib: OK"
    else
        warn "  $lib 未安装，正在安装..."
        $PYTHON_CMD -m pip install "$lib" -q || error "安装 $lib 失败"
    fi
done

# -----------------------------------------------------------------------------
# Step 2: 读取 Hermes 配置
# -----------------------------------------------------------------------------
info "Step 2: 读取 Hermes 配置..."

extract_env() {
    local key="$1" file="$2"
    grep "^${key}=" "$file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo ""
}

FEISHU_APP_ID="" FEISHU_APP_SECRET="" FEISHU_BOT_OPEN_ID=""
HERMES_PORT="18999"

HERMES_ENV="$PROFILE_DIR/.env"
HERMES_CONFIG="$PROFILE_DIR/config.yaml"

if [[ -f "$HERMES_ENV" ]]; then
    info "  读取 .env..."
    FEISHU_APP_ID=$(extract_env "FEISHU_APP_ID" "$HERMES_ENV")
    FEISHU_APP_SECRET=$(extract_env "FEISHU_APP_SECRET" "$HERMES_ENV")
    FEISHU_BOT_OPEN_ID=$(extract_env "FEISHU_BOT_OPEN_ID" "$HERMES_ENV")
fi

if [[ -f "$HERMES_CONFIG" ]]; then
    info "  检查 config.yaml..."
    BOT_OPEN_ID_YAML=$(grep -E "^\s*bot_open_id:" "$HERMES_CONFIG" 2>/dev/null | head -1 | awk '{print $2}' || echo "")
    [[ -n "$BOT_OPEN_ID_YAML" && -z "$FEISHU_BOT_OPEN_ID" ]] && FEISHU_BOT_OPEN_ID="$BOT_OPEN_ID_YAML"
fi

# -----------------------------------------------------------------------------
# Step 3: 确认配置（不再重新输入，只显示已读取的值）
# -----------------------------------------------------------------------------
info "Step 3: 确认配置..."

echo ""
echo "  bot-pollerd 配置"
echo "  Hermes Webhook Port: ${HERMES_PORT}"
echo ""
echo "  如需修改请直接输入新值（回车保持不变）："
echo ""

read -r -p "Feishu App ID [${FEISHU_APP_ID}]: " tmp || true
[[ -n "$tmp" ]] && FEISHU_APP_ID="$tmp"

read -r -p "Bot Open ID [${FEISHU_BOT_OPEN_ID}]: " tmp || true
[[ -n "$tmp" ]] && FEISHU_BOT_OPEN_ID="$tmp"

echo -n "Hermes Webhook Port [${HERMES_PORT}]: "
read -r tmp || true; [[ -n "$tmp" ]] && HERMES_PORT="$tmp"

# -----------------------------------------------------------------------------
# Step 4: 读取已有配置（如存在）用于记住上次选择
# -----------------------------------------------------------------------------
info "Step 4: 配置监控群..."

if [[ -f "$POLLERD_CONFIG_FILE" ]]; then
    info "  检测到已有配置，读取上次选择..."
    exec 4< "$POLLERD_CONFIG_FILE"
    while IFS= read -r line <&4 || true; do
        if [[ "$line" =~ chat_id:\ \"([^\"]+)\" ]]; then
            cur_chat="${BASH_REMATCH[1]}"
        fi
        if [[ -n "$cur_chat" && "$line" =~ mode:\ \"([^\"]+)\" ]]; then
            CHAT_MODE_PREVIOUS["$cur_chat"]="${BASH_REMATCH[1]}"
        fi
    done
    exec 4<&-
fi

echo ""
echo -e "${BOLD}支持的群模式:${NC}"
echo -e "  ${BOLD}1)${NC} at_only     - 只处理 @ 本 bot 的消息"
echo -e "  ${BOLD}2)${NC} mention_all - 处理 @ 了任何人的消息（支持 bot @ bot）"
echo -e "  ${BOLD}3)${NC} free_at     - 免@模式（白名单 bot 发来的无 @ 消息）"
echo ""

# 从 Hermes 配置读取已知群
declare -A CHAT_MAP
KNOWN_CHATS=(
    "oc_b70407312481c83d1918c34f7e16a7f1:西游团队群"
    "oc_629f6534bd95cc0730b791f8a1456397:群2"
    "oc_22e019265c6096916f5a78de44f3cdea:群3"
)

for chat_info in "${KNOWN_CHATS[@]}"; do
    chat_id="${chat_info%%:*}"
    chat_name="${chat_info#*:}"
    CHAT_MAP["$chat_id"]="$chat_name"
done

echo -e "${BOLD}检测到以下群（共 ${#CHAT_MAP[@]} 个）：${NC}"
echo ""

declare -a CHAT_IDS_ORDERED
INDEX=1
for chat_id in "${!CHAT_MAP[@]}"; do
    chat_name="${CHAT_MAP[$chat_id]}"
    prev_mode="${CHAT_MODE_PREVIOUS[$chat_id]:-}"
    prev_display=""
    [[ -n "$prev_mode" ]] && prev_display="(${YELLOW}上次: $prev_mode${NC})"
    echo -e "  ${BOLD}[$INDEX]${NC} ${CYAN}${chat_name}${NC}"
    echo -e "       ID: ${chat_id} $prev_display"
    echo -e "       模式: ${BOLD}1${NC}=at_only  ${BOLD}2${NC}=mention_all  ${BOLD}3${NC}=free_at"
    echo ""
    CHAT_IDS_ORDERED+=("$chat_id")
    INDEX=$((INDEX + 1))
done

# 批量选择
NUM_CHATS=${#CHAT_IDS_ORDERED[@]}
echo -e "${BOLD}请为每个群选择模式（输入 ${NUM_CHATS} 个数字，如："
echo -e "  回车=使用上次配置，直接输入如 ${CYAN}313${NC} = 群1=free_at 群2=at_only 群3=free_at）:${NC}"
echo -n "  你的选择: "
read -r BATCH_MODE_INPUT || true
echo ""

declare -a CHAT_IDS
declare -a CHAT_MODES

if [[ -z "$BATCH_MODE_INPUT" && ${#CHAT_MODE_PREVIOUS[@]} -gt 0 ]]; then
    # 使用上次配置
    info "使用上次配置"
    for chat_id in "${CHAT_IDS_ORDERED[@]}"; do
        CHAT_IDS+=("$chat_id")
        CHAT_MODES+=("${CHAT_MODE_PREVIOUS[$chat_id]}")
    done
elif [[ -z "$BATCH_MODE_INPUT" ]]; then
    # 无历史，逐个询问
    warn "无历史配置，逐个选择模式"
    for chat_id in "${CHAT_IDS_ORDERED[@]}"; do
        chat_name="${CHAT_MAP[$chat_id]:-未知}"
        echo -e "  群: ${CYAN}${chat_name}${NC}"
        echo -n "  模式 (1=at_only, 2=mention_all, 3=free_at) [3]: "
        read -r mode_num || true
        case "${mode_num:-3}" in
            1) MODE="at_only" ;;
            2) MODE="mention_all" ;;
            *) MODE="free_at" ;;
        esac
        CHAT_IDS+=("$chat_id")
        CHAT_MODES+=("$MODE")
    done
else
    # 解析输入
    IDX=0
    for ((i=0; i<${#BATCH_MODE_INPUT}; i++)); do
        char="${BATCH_MODE_INPUT:$i:1}"
        chat_id="${CHAT_IDS_ORDERED[$IDX]}"
        case "$char" in
            1) MODE="at_only" ;;
            2) MODE="mention_all" ;;
            *) MODE="free_at" ;;
        esac
        CHAT_IDS+=("$chat_id")
        CHAT_MODES+=("$MODE")
        IDX=$((IDX + 1))
    done
    # 不够3位，补全
    while [[ $IDX -lt ${#CHAT_IDS_ORDERED[@]} ]]; do
        chat_id="${CHAT_IDS_ORDERED[$IDX]}"
        prev="${CHAT_MODE_PREVIOUS[$chat_id]:-free_at}"
        CHAT_IDS+=("$chat_id")
        CHAT_MODES+=("$prev")
        IDX=$((IDX + 1))
    done
fi

# 显示选择结果
echo ""
echo -e "${BOLD}已选择的群配置：${NC}"
for i in "${!CHAT_IDS[@]}"; do
    chat_name="${CHAT_MAP[${CHAT_IDS[$i]}]:-未知群}"
    echo -e "  ${GREEN}✓${NC} ${chat_name}: ${CHAT_MODES[$i]}"
done

# 添加更多群
echo ""
read -r -p "是否添加更多群？[y/N]: " confirm || true
while [[ "$confirm" =~ ^[Yy]$ ]]; do
    read -r -p "  群 ID (oc_xxx): " NEW_CHAT_ID || true
    read -r -p "  群名称: " NEW_CHAT_NAME || true
    echo -n "  模式 (1=at_only, 2=mention_all, 3=free_at) [3]: "
    read -r mode_num || true
    echo
    case "${mode_num:-3}" in
        1) MODE="at_only" ;;
        2) MODE="mention_all" ;;
        *) MODE="free_at" ;;
    esac
    CHAT_IDS+=("$NEW_CHAT_ID")
    CHAT_MODES+=("$MODE")
    CHAT_MAP["$NEW_CHAT_ID"]="$NEW_CHAT_NAME"
    success "已添加: $NEW_CHAT_NAME ($MODE)"
    echo ""
    read -r -p "继续添加？[y/N]: " confirm || true
done

if [[ ${#CHAT_IDS[@]} -eq 0 ]]; then
    warn "未配置任何群，安装中止"
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 5: 免@白名单
# -----------------------------------------------------------------------------
info "Step 5: 配置免@白名单..."

echo ""
echo -e "${BOLD}免@白名单 - 哪些 bot 的消息可以在 free_at 模式被处理${NC}"
echo "（输入 open_id，多个用逗号分隔，直接回车使用默认值）"
echo ""
echo "已知 bot open_id:"
echo "  bailong-hermes: ou_043010649f6b148adcc493b68f8e0478"
echo "  wk-hermes:      ou_811266eb548e3ab3ad06a76ec8a2e291"
echo "  mao:            ou_95664eced41bf683c09aa88287f72203"
echo ""
read -r -p "白名单 [默认: 以上三个]: " WHITELIST_INPUT || true

DEFAULT_WHITELIST="ou_043010649f6b148adcc493b68f8e0478,ou_811266eb548e3ab3ad06a76ec8a2e291,ou_95664eced41bf683c09aa88287f72203"
WHITELIST="${WHITELIST_INPUT:-$DEFAULT_WHITELIST}"
IFS=',' read -ra WL_ARRAY <<< "$WHITELIST"

# -----------------------------------------------------------------------------
# Step 6: 更新 Hermes .env（注入 Webhook 端口）
# -----------------------------------------------------------------------------
info "Step 6: 更新 Hermes 配置..."

ENV_FILE="$PROFILE_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    if ! grep -q "POLLERD_WEBHOOK_PORT" "$ENV_FILE" 2>/dev/null; then
        echo "POLLERD_WEBHOOK_PORT=$HERMES_PORT" >> "$ENV_FILE"
        info "  已添加 POLLERD_WEBHOOK_PORT=$HERMES_PORT 到 .env"
    else
        info "  POLLERD_WEBHOOK_PORT 已存在"
    fi
    if [[ -n "$FEISHU_BOT_OPEN_ID" ]] && ! grep -q "FEISHU_BOT_OPEN_ID" "$ENV_FILE" 2>/dev/null; then
        echo "FEISHU_BOT_OPEN_ID=$FEISHU_BOT_OPEN_ID" >> "$ENV_FILE"
        info "  已添加 FEISHU_BOT_OPEN_ID 到 .env"
    fi
else
    warn "  .env 不存在，跳过"
fi

# -----------------------------------------------------------------------------
# Step 7: 生成 pollerd.yaml（通过 Python 生成，确保 YAML 格式正确）
# -----------------------------------------------------------------------------
info "Step 7: 生成 pollerd.yaml..."

$PYTHON_CMD - "$PROFILE" "$FEISHU_APP_ID" "$FEISHU_APP_SECRET" "$FEISHU_BOT_OPEN_ID" "$HERMES_PORT" "$POLLERD_CONFIG_FILE" \
    "${CHAT_IDS[*]}" "${CHAT_MODES[*]}" "${WL_ARRAY[*]}" << 'PYTHON_EOF'
import sys, yaml

profile = sys.argv[1]
app_id = sys.argv[2]
app_secret = sys.argv[3]
bot_open_id = sys.argv[4]
hermes_port = sys.argv[5]
config_path = sys.argv[6]

# 空格分隔的字符串转列表
chat_ids = sys.argv[7].split()
chat_modes = sys.argv[8].split()
whitelist = sys.argv[9].split()

config = {
    'feishu': {
        'app_id': app_id,
        'app_secret': app_secret,
        'bot_open_id': bot_open_id,
    },
    'hermes': {
        'host': '127.0.0.1',
        'port': int(hermes_port),
    },
    'polling': {
        'interval_seconds': 3,
        'batch_size': 20,
    },
    'chatrooms': [
        {'chat_id': cid, 'mode': mode, 'enabled': True}
        for cid, mode in zip(chat_ids, chat_modes)
    ],
    'free_at_whitelist': whitelist,
}

with open(config_path, 'w') as f:
    f.write('# bot-pollerd 配置文件\n')
    f.write(f'# profile: {profile}\n')
    f.write('# 由 install.sh 自动生成\n\n')
    yaml.dump(config, f, allow_unicode=True, default_flow_style=False, sort_keys=False)

print("Config written")
PYTHON_EOF

success "配置文件已写入: $POLLERD_CONFIG_FILE"

# -----------------------------------------------------------------------------
# Step 8: 生成 systemd service 文件
# -----------------------------------------------------------------------------
info "Step 8: 生成 systemd service..."

POLLERD_SERVICE="$REAL_HOME/.config/systemd/user/pollerd@.service"
mkdir -p "$(dirname "$POLLERD_SERVICE")"

PYTHON_PATH=$(command -v $PYTHON_CMD)

cat > "$POLLERD_SERVICE" << EOF
# =============================================================================
# bot-pollerd systemd service for profile: $PROFILE
# =============================================================================
[Unit]
Description=bot-pollerd for %p
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=${POLLERD_DIR}
ExecStart=${PYTHON_PATH} -m bot_pollerd --profile %p
Restart=always
RestartSec=5
Environment="PYTHONPATH=${POLLERD_DIR}"

[Install]
WantedBy=multi-user.target
EOF

success "Service 文件已写入: $POLLERD_SERVICE"

# -----------------------------------------------------------------------------
# Step 9: 安装 Python 模块
# -----------------------------------------------------------------------------
info "Step 9: 安装 bot-pollerd 模块..."

mkdir -p "$PROFILE_DIR/modules"
ln -sf "$POLLERD_DIR" "$PROFILE_DIR/modules/bot_pollerd" 2>/dev/null || true

success "模块链接已创建: $PROFILE_DIR/modules/bot_pollerd -> $POLLERD_DIR"

# -----------------------------------------------------------------------------
# Step 10: 重载 systemd
# -----------------------------------------------------------------------------
info "Step 10: 重载 systemd..."
if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload 2>/dev/null || true
    success "systemd 已重载"
else
    warn "systemctl 不可用，跳过"
fi

# -----------------------------------------------------------------------------
# 完成
# -----------------------------------------------------------------------------
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
echo "配置文件: $POLLERD_CONFIG_FILE"
echo "Service: $POLLERD_SERVICE"
echo ""
