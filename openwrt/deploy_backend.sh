#!/bin/bash
# deploy_backend.sh —— 在路由器上本地构建并部署 sing-box-subscribe 后端（Docker）
#
# 为什么需要一个脚本：本项目的「后端」是第三方项目 Toperlock/sing-box-subscribe（Python/Flask），
# 官方没有发布镜像，社区镜像（例如 hestudy/...）年久失修且存在真实缺陷（base64 订阅会 500）。
# 这里把「取源码 → docker build → 起容器 → 健康检查 → 端到端校验」固化成可重复执行的流程，
# 失败时保留/回滚旧容器，避免把本来能用的后端换成一个起不来的。
#
# 用法：
#   deploy_backend.sh                 # 构建 + 部署 + 健康检查 + 端到端校验
#   deploy_backend.sh --build-only    # 只构建镜像，不动容器
#   deploy_backend.sh --skip-e2e      # 跳过「用真实订阅生成一次配置」的校验
#   deploy_backend.sh --ref main      # 跟随上游 main（默认固定 commit，可复现）
#   deploy_backend.sh --name my-sb    # 自定义容器名（默认 sbshell-backend）
set -Eeuo pipefail

_sbshell_lib_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$_sbshell_lib_dir/lib.sh" || { echo '缺少 lib.sh，请先在菜单 9 更新脚本。' >&2; exit 1; }

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 上游与镜像参数
BACKEND_REPO='Toperlock/sing-box-subscribe'
# 默认固定的上游 commit（2026-09-29，vless tls 修复后）。改这里并同步 README 即可升级。
BACKEND_PIN='25f9fd20d2c51420f8ef378e6d211f5937ad1caf'
IMAGE_REPO='sbshell-backend'
CONTAINER_NAME='sbshell-backend'
BACKEND_PORT=5000
WAIT_SECS=${SBSHELL_BACKEND_WAIT_SECS:-60}
BUILD_ROOT=${SBSHELL_BACKEND_BUILD_ROOT:-/root/sbshell-backend-build}
MIN_FREE_KB=2097152   # 2 GiB：基础镜像 + pip 依赖 + 构建缓存的安全线
DEFAULTS_FILE=${SBSHELL_DEFAULTS_FILE:-/etc/sing-box/defaults.conf}
MANUAL_FILE=${SBSHELL_MANUAL_FILE:-/etc/sing-box/manual.conf}

REF="$BACKEND_PIN"
BUILD_ONLY=0
SKIP_E2E=0
FORCE=0
WORK_DIR=''
KEEP_WORK=0

usage() {
    cat <<'EOS'
用法: deploy_backend.sh [选项]

  --ref <commit|main>  源码版本（默认内置的固定 commit；main 表示跟随上游最新）
  --name <容器名>      容器名（默认 sbshell-backend）
  --build-only         只构建镜像，不重建容器
  --skip-e2e           跳过端到端校验（不调用订阅生成配置）
  --force              端口已被其它进程占用时仍然继续
  -h, --help           显示本帮助
EOS
}

log() { echo -e "${CYAN}[$1]${NC} $2"; }
ok() { echo -e "${GREEN}✔ $1${NC}"; }
warn() { echo -e "${YELLOW}警告：$1${NC}" >&2; }
die() { echo -e "${RED}✘ $1${NC}" >&2; exit 1; }

cleanup() {
    [ "$KEEP_WORK" = 1 ] || [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --ref) REF="${2:-}"; [ -n "$REF" ] || die '--ref 需要一个参数'; shift 2 ;;
            --name) CONTAINER_NAME="${2:-}"; [ -n "$CONTAINER_NAME" ] || die '--name 需要一个参数'; shift 2 ;;
            --build-only) BUILD_ONLY=1; shift ;;
            --skip-e2e) SKIP_E2E=1; shift ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数：$1（--help 查看用法）" ;;
        esac
    done
    # 容器名要能直接放进 docker 命令；限制字符集避免参数注入。
    case "$CONTAINER_NAME" in
        *[!A-Za-z0-9_.-]*) die "容器名只能包含字母、数字、下划线、点和短横线：$CONTAINER_NAME" ;;
    esac
}

# ---------- 1. 预检 ----------
preflight() {
    log 1/6 '预检（root / docker / 磁盘 / 网络）'
    [ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
    command -v docker >/dev/null 2>&1 || die '未找到 docker：请先安装并启动 Docker（或使用社区镜像方案）。'
    docker info >/dev/null 2>&1 || die 'docker 守护进程未运行：请先启动 dockerd（/etc/init.d/dockerd start）。'
    local free_kb
    free_kb=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')
    case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
    if [ "$free_kb" -lt "$MIN_FREE_KB" ] 2>/dev/null; then
        warn "根分区可用空间只有 $((free_kb / 1024)) MiB，构建约需 2 GiB；空间不足会中途失败。"
    fi
    if ! curl --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 8 --max-time 20 \
        -o /dev/null "https://github.com/$BACKEND_REPO" 2>/dev/null; then
        die "无法访问 github.com：构建需要先拉取源码（$BACKEND_REPO）。"
    fi
    ok "docker 可用，根分区可用 $((free_kb / 1024)) MiB"
}

# ---------- 2. 取源码 ----------
fetch_source() {
    log 2/6 "拉取源码 $BACKEND_REPO@$REF"
    WORK_DIR=$(mktemp -d "${BUILD_ROOT}.XXXXXX") || die "无法在 $(dirname "$BUILD_ROOT") 创建构建目录"
    local tarball="$WORK_DIR/src.tar.gz"
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 300 \
        -o "$tarball" "https://github.com/$BACKEND_REPO/archive/$REF.tar.gz"; then
        KEEP_WORK=1
        die "源码下载失败（$REF）。若是固定 commit 已不存在，请用 --ref main 跟随上游。"
    fi
    tar -xzf "$tarball" -C "$WORK_DIR" || { KEEP_WORK=1; die '源码解包失败。'; }
    local src
    src=$(find "$WORK_DIR" -maxdepth 1 -type d -name 'sing-box-subscribe-*' | head -n1)
    [ -n "$src" ] && [ -f "$src/Dockerfile" ] || { KEEP_WORK=1; die '源码结构异常：未找到 Dockerfile。'; }
    SRC_DIR="$src"
    ok "源码就绪：$SRC_DIR"
}

# ---------- 3. 构建镜像 ----------
image_tag() {
    case "$REF" in
        *[!0-9a-fA-F]*) printf '%s' "$REF" ;;
        *) printf '%s' "${REF:0:7}" ;;
    esac
}

build_image() {
    log 3/6 "docker build（约 3~10 分钟，取决于网速与机器）"
    IMAGE_TAG=$(image_tag)
    IMAGE_FULL="$IMAGE_REPO:$IMAGE_TAG"
    local logfile="$WORK_DIR/build.log"
    # --pull：基础镜像取最新补丁；--network host：pip 需要出网（BuildKit 也认这个参数）。
    if ! docker build --pull --network host -t "$IMAGE_FULL" "$SRC_DIR" 2>&1 | tee "$logfile"; then
        KEEP_WORK=1
        echo '--- 构建日志尾部 ---' >&2
        tail -n 30 "$logfile" >&2 || true
        die "镜像构建失败（日志：$logfile）。现有容器未受影响。"
    fi
    docker image inspect "$IMAGE_FULL" >/dev/null 2>&1 || die "构建完成但镜像不存在：$IMAGE_FULL"
    ok "镜像就绪：$IMAGE_FULL"
}

# ---------- 4. 切换容器 ----------
port_busy() {
    curl --silent --max-time 2 -o /dev/null "http://127.0.0.1:$BACKEND_PORT/" 2>/dev/null
}

container_exists() {
    docker inspect "$1" >/dev/null 2>&1
}

deploy_container() {
    log 4/6 "部署容器 $CONTAINER_NAME（host 网络，端口 $BACKEND_PORT）"
    PREV_IMAGE=''
    if container_exists "$CONTAINER_NAME"; then
        PREV_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)
        if [ -n "$PREV_IMAGE" ]; then
            docker tag "$PREV_IMAGE" "$IMAGE_REPO:previous" 2>/dev/null || true
        fi
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    elif port_busy; then
        # 端口已被别的容器占着（例如老的 hestudy 镜像）。不动它，避免把用户的现有后端弄坏。
        if [ "$FORCE" != 1 ]; then
            die "端口 $BACKEND_PORT 已有服务在监听（可能是旧后端容器）。请先停止它，或用 --force 继续。"
        fi
        warn "端口 $BACKEND_PORT 已被占用：--force 继续，新容器可能因端口冲突起不来。"
    fi
    # sbshell 通过 127.0.0.1:5000 访问后端，容器必须与宿主共享网络命名空间。
    if ! docker run -d --name "$CONTAINER_NAME" --network host --restart unless-stopped "$IMAGE_FULL" >/dev/null; then
        rollback_container
        die '容器启动失败，已尝试回滚。'
    fi
    ok "容器已启动：$CONTAINER_NAME（$IMAGE_FULL）"
}

rollback_container() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if [ -n "$PREV_IMAGE" ] && docker image inspect "$IMAGE_REPO:previous" >/dev/null 2>&1; then
        warn "正在回滚到之前的镜像：$PREV_IMAGE"
        docker run -d --name "$CONTAINER_NAME" --network host --restart unless-stopped "$IMAGE_REPO:previous" >/dev/null 2>&1 \
            && ok '已回滚，旧后端继续运行。' \
            || warn '回滚也失败了：请检查 docker ps -a 与 docker logs。'
    fi
}

# ---------- 5. 健康检查 ----------
wait_healthy() {
    log 5/6 "健康检查 http://127.0.0.1:$BACKEND_PORT/（最多 60 秒）"
    local waited=0
    while [ "$waited" -lt "$WAIT_SECS" ]; do
        if curl --fail --silent --max-time 3 -o /dev/null "http://127.0.0.1:$BACKEND_PORT/"; then
            ok "后端已就绪（等待 ${waited}s）"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    echo '--- docker logs（尾部）---' >&2
    docker logs --tail 30 "$CONTAINER_NAME" 2>&1 >&2 || true
    rollback_container
    die "健康检查失败（${WAIT_SECS}s 内 / 未返回 200），已尝试回滚到旧镜像。"
}

# ---------- 6. 端到端校验 ----------
e2e_check() {
    log 6/6 '端到端校验（用已保存的订阅 + 模板生成一次配置并 sing-box check）'
    local backend sub tpl code body err
    backend=$(default_or_factory BACKEND_URL)
    sub=$(default_or_factory SUBSCRIPTION_URL)
    tpl=$(resolve_default TUN_TEMPLATE_URL TEMPLATE_URL 0)
    tpl=${tpl:-$(factory_default TUN_TEMPLATE_URL)}
    if [ -z "$backend" ] || [ -z "$sub" ]; then
        warn '还没配置后端/订阅（菜单 6），跳过端到端校验；可用菜单 2 配置后再验证。'
        return 0
    fi
    if ! command -v sing-box >/dev/null 2>&1; then
        warn '未找到 sing-box，跳过端到端校验（健康检查已通过）。'
        return 0
    fi
    local url="${backend%/}/config/${sub}&file=${tpl}"
    body=$(mktemp /tmp/sbshell-backend-body.XXXXXX)
    err=$(mktemp /tmp/sbshell-backend-err.XXXXXX)
    code=$(curl --silent --show-error --location --proto '=http,https' --tlsv1.2 \
        --connect-timeout 10 --max-time 120 -o "$body" -w '%{http_code}' \
        "$url" 2>"$err" || echo 000)
    case "$code" in ''|*[!0-9]*) code=000 ;; esac
    case "$code" in
        200) : ;;
        000)
            if grep -qi 'refused\|Could not connect' "$err" 2>/dev/null; then
                rm -f "$body" "$err"
                die "后端未响应（连接被拒绝）：容器可能刚崩溃，查看 docker logs $CONTAINER_NAME。"
            fi
            echo "--- curl 错误 ---" >&2; head -c 300 "$err" >&2 || true; echo >&2
            rm -f "$body" "$err"
            die '无法连接后端（网络错误）。'
            ;;
        5??)
            echo "--- 后端返回的响应体（前 400 字节，通常写明原因）---" >&2
            head -c 400 "$body" >&2 || true; echo >&2
            rm -f "$body" "$err"
            die "后端返回 HTTP $code：请检查上游订阅（$sub 的主机）与模板地址是否可达。"
            ;;
        *) echo "--- 响应体（前 300 字节）---" >&2; head -c 300 "$body" >&2 || true; echo >&2
           rm -f "$body" "$err"
           die "后端返回 HTTP $code。" ;;
    esac
    if [ ! -s "$body" ]; then
        rm -f "$body" "$err"
        die '后端返回 200 但内容为空。'
    fi
    if ! sing-box check -c "$body" >/dev/null 2>&1; then
        echo '--- sing-box check 输出 ---' >&2
        sing-box check -c "$body" 2>&1 | head -n 10 >&2 || true
        rm -f "$body" "$err"
        die '生成的配置没有通过 sing-box check：多为模板与本地 sing-box 版本不匹配（本项目要求 1.14+）。'
    fi
    rm -f "$body" "$err"
    ok '端到端校验通过：后端可用，且模板能生成 1.14+ 合法配置'
}

main() {
    parse_args "$@"
    preflight "$@"
    fetch_source
    build_image
    if [ "$BUILD_ONLY" = 1 ]; then
        ok "仅构建模式完成：$IMAGE_FULL（未改动容器）"
        exit 0
    fi
    deploy_container
    wait_healthy
    if [ "$SKIP_E2E" = 1 ]; then
        warn '已跳过端到端校验（--skip-e2e）。'
    else
        e2e_check
    fi
    echo
    ok '后端部署完成。'
    echo -e "${CYAN}下一步：菜单 6 确认后端/订阅/模板地址，再运行菜单 2 拉取配置。${NC}"
}

main "$@"
