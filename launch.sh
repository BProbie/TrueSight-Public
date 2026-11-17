#!/usr/bin/env bash
# =============================================================================
# launch.sh —— 一键启动（Linux / macOS）
#
# 用法：
#   ./launch.sh                  # 本地模式，127.0.0.1:8000
#   ./launch.sh public 8010      # 只读脱敏模式，端口 8010
#
# 首次运行会自动准备环境（建 venv、装依赖、生成 .env），逻辑与
# scripts/launch.ps1 一致；Windows 请用根目录的 launch.bat。
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$ROOT/server"
FRONTEND="$ROOT/frontend"
# shellcheck source=scripts/frontend-deps.sh
. "$ROOT/scripts/frontend-deps.sh"
# 与 Windows 共用仓库时，server/.venv 可能是 Windows 创建的（没有 bin/python）。
# 不删除它，改用 Linux 专用 server/.venv-linux，避免破坏另一平台的运行环境。
VENV="$SERVER/.venv"
if [ -d "$VENV" ] && [ ! -x "$VENV/bin/python" ]; then
    VENV="$SERVER/.venv-linux"
fi
PYTHON="$VENV/bin/python"

CONFIG_FILE="$ROOT/truesight.config.json"

info() { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$1"; }

# 先定位系统 Python：读取根配置与创建 venv 都依赖它。
PY_BIN="$(command -v python3.12 || command -v python3 || true)"

# 读取 truesight.config.json 的某个键；缺失或解析失败时返回内置默认值。
config_value() {
    local key="$1"
    local fallback="$2"
    if [ -z "$PY_BIN" ] || [ ! -f "$CONFIG_FILE" ]; then
        printf '%s\n' "$fallback"
        return
    fi
    "$PY_BIN" - "$CONFIG_FILE" "$key" "$fallback" <<'PY'
import json
import sys

config_path, key, fallback = sys.argv[1:4]
try:
    with open(config_path, encoding="utf-8") as handle:
        value = json.load(handle)
    for part in key.split("."):
        value = value[part]
    print(value if value not in (None, "") else fallback)
except Exception:
    print(fallback)
PY
}

# 优先级：命令行 > 环境变量 > truesight.config.json > 内置默认。
MODE="${1:-${TRUESIGHT_MODE:-}}"
if [ -z "$MODE" ]; then MODE="$(config_value server.mode local)"; fi
PORT="${2:-${TRUESIGHT_PORT:-}}"
if [ -z "$PORT" ]; then PORT="$(config_value server.port 8000)"; fi
HOST="${TRUESIGHT_HOST:-}"
if [ -z "$HOST" ]; then HOST="$(config_value server.host 127.0.0.1)"; fi
PUBLIC_BASE_URL="${TRUESIGHT_PUBLIC_BASE_URL:-}"
if [ -z "$PUBLIC_BASE_URL" ]; then
    PUBLIC_BASE_URL="$(config_value public.base_url "http://127.0.0.1:${PORT}")"
fi
# 根配置保留默认 localhost 地址时，让它跟随实际端口。
if [ "$PUBLIC_BASE_URL" = "http://127.0.0.1:8000" ] && [ "$PORT" != "8000" ]; then
    PUBLIC_BASE_URL="http://127.0.0.1:${PORT}"
fi

case "$MODE" in
    local|public) ;;
    *)
        warn "运行模式只能是 local 或 public，收到：$MODE"
        exit 1
        ;;
esac

echo ""
echo "  TrueSight / 明鉴 —— 旁路式仿冒检测防护系统"
echo "  模式：$MODE    监听：$HOST:$PORT"
echo "  公网地址：$PUBLIC_BASE_URL"
echo ""

# -- 1) 环境 ----------------------------------------------------------------
# Linux 虚拟环境自身损坏（例如安装中断）时重建；Windows 的 server/.venv
# 已在上面被排除，不会被删除。
if [ -d "$VENV" ] && [ ! -x "$PYTHON" ]; then
    warn "Linux 虚拟环境不可用，将重建：$VENV"
    rm -rf "$VENV"
fi

if [ ! -x "$PYTHON" ]; then
    info "首次运行：创建虚拟环境并安装依赖"
    if [ -z "$PY_BIN" ]; then
        warn "未找到 Python 3.12，请先安装（https://www.python.org/downloads/）"
        exit 1
    fi
    "$PY_BIN" -m venv "$VENV"
    "$PYTHON" -m pip install --upgrade pip
    ( cd "$SERVER" && "$PYTHON" -m pip install -e ".[dev]" )
elif ! "$PYTHON" -c "import fastapi" >/dev/null 2>&1; then
    # 上次安装中断会留下「只有解释器、没有依赖」的半成品环境。
    warn "Linux 虚拟环境缺少依赖，正在补齐安装"
    "$PYTHON" -m pip install --upgrade pip
    ( cd "$SERVER" && "$PYTHON" -m pip install -e ".[dev]" )
else
    echo "环境已就绪（复用 $VENV）"
fi

# -- 2) 配置 ----------------------------------------------------------------
if [ ! -f "$SERVER/.env" ]; then
    cp "$SERVER/.env.example" "$SERVER/.env"
    warn "已生成 server/.env —— 请替换 TRUESIGHT_SECRET_KEY 后再对外提供服务"
fi

# -- 3) 前端（可选，失败不阻塞）--------------------------------------------
if [ ! -f "$FRONTEND/apps/web-client/dist/index.html" ]; then
    if command -v npm >/dev/null 2>&1; then
        info "构建前端页面（首次运行需要一两分钟）"
        ensure_frontend_deps "$FRONTEND"
        if ( cd "$FRONTEND" && npm run build ); then
            :
        else
            warn "前端构建失败：页面不可用，但接口与检测能力不受影响"
        fi
    else
        warn "未找到 Node，跳过前端构建（接口可用，只是没有页面）"
    fi
fi

# -- 4) 启动 ----------------------------------------------------------------
echo ""
echo "  公网侧页面：http://127.0.0.1:$PORT/"
if [ "$MODE" = "local" ]; then
    echo "  管理后台：  http://127.0.0.1:$PORT/admin/"
    echo "  平台控制台：http://127.0.0.1:$PORT/root/"
else
    echo "  公网模式：无管理后台（只提供脱敏数据与举报受理）"
fi
echo "  健康检查：  http://127.0.0.1:$PORT/healthz"
echo "  按 Ctrl+C 停止服务"
echo ""

export TRUESIGHT_MODE="$MODE"
export TRUESIGHT_HOST="$HOST"
export TRUESIGHT_PORT="$PORT"
export TRUESIGHT_PUBLIC_BASE_URL="$PUBLIC_BASE_URL"

cd "$SERVER"
exec "$PYTHON" -m uvicorn app.main:create_app --factory --host "$HOST" --port "$PORT"
