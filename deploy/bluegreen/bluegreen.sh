#!/usr/bin/env bash
# =============================================================================
# Sub2API blue-green deployment helper
# =============================================================================
# Runs the application as two interchangeable slots (blue / green) behind a
# small Caddy edge container, so an upgrade becomes:
#
#   1. start the new version in the idle slot
#   2. wait until /health answers
#   3. point the edge at it (single Caddyfile fragment + graceful reload)
#   4. keep or stop the old slot afterwards
#
# The database and Redis of the existing deployment are reused as-is; this
# script never starts, stops or migrates them.
#
# Usage: ./bluegreen.sh <command> [options]
# Run `./bluegreen.sh help` for the command list.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.bg.yml"
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
STATE_FILE="$RUNTIME_DIR/state.env"
MOUNT_FILE="$RUNTIME_DIR/mount.yml"
UPSTREAM_FILE="$RUNTIME_DIR/upstream.caddy"

EDGE_CONTAINER="sub2api-edge"
EDGE_PROJECT="sub2api-bg"
LEGACY_CONTAINER="sub2api"
SLOT_PREFIX="sub2api"

ENV_FILE="${BG_ENV_FILE:-$DEPLOY_DIR/.env}"
DEFAULT_IMAGE="${BG_IMAGE_DEFAULT:-weishaw/sub2api:latest}"
HEALTH_TIMEOUT="${BG_HEALTH_TIMEOUT:-1800}"

COMPOSE_V2=1

# Runtime state (overwritten by load_state)
ACTIVE=""
PREVIOUS=""
IMAGE_BLUE=""
IMAGE_GREEN=""
BG_NETWORK=""
BG_DATA_TYPE=""
BG_DATA_SOURCE=""
BG_EDGE_PORT="8080"
BG_EDGE_BIND_IP="0.0.0.0"
BG_BLUE_PORT="18080"
BG_GREEN_PORT="18081"
BG_BIND_IP="127.0.0.1"
BG_TRUSTED_PROXIES=""
BG_IMAGE_RUN=""

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
info() { printf '[bluegreen] %s\n' "$*"; }
warn() { printf '[bluegreen] WARNING: %s\n' "$*" >&2; }
die() { printf '[bluegreen] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Sub2API 蓝绿部署工具

用法: ./bluegreen.sh <command> [options]

命令:
  init [--force]              初始化:检测现有部署 → 启动 blue → 接管端口 → 启动 edge
                              首次切换会有 2~5 秒端口交接空窗(旧容器停止 → edge 启动)
  deploy [--image TAG] [--stop-old[=SECS]]
                              把镜像 TAG 部署到空闲槽位,健康检查通过后切流
                              --stop-old       切流后等待 SECS 秒(默认 300)再停旧槽位
                              --keep-old       保留旧槽位(默认行为)
  rollback                    切回上一个槽位;若它已停止会用记录的镜像重新拉起
  switch <blue|green>         手动切到指定槽位(必须已在运行且健康)
  status                      查看两个槽位、镜像与当前上游顺序
  start <blue|green>          启动一个已停止的槽位(不切流)
  stop <blue|green>           停止一个槽位(请确认没有在途流式请求)
  logs <blue|green|edge> [-f] 查看日志
  destroy                     停止并删除 edge 与两个槽位容器(不碰数据库)
  render-mount <bind|volume> <source>
                              内部命令,用于测试数据挂载的 YAML 生成

环境变量:
  BG_ENV_FILE        现有部署的 .env 路径(默认:仓库 deploy/.env)
  BG_IMAGE_DEFAULT   默认镜像(默认:weishaw/sub2api:latest)
  BG_HEALTH_TIMEOUT  等待新槽位就绪的超时秒数(默认:1800)
  BG_NETWORK         覆盖自动检测的 docker 网络名
  BG_TRUSTED_PROXIES 覆盖自动检测的反向代理 CIDR

示例:
  ./bluegreen.sh init
  ./bluegreen.sh deploy --image weishaw/sub2api:0.2.21
  ./bluegreen.sh deploy --image weishaw/sub2api:0.2.21 --stop-old=600
  ./bluegreen.sh rollback
EOF
}

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
require_docker() {
	command -v docker >/dev/null 2>&1 || die "未找到 docker 命令"
	docker info >/dev/null 2>&1 || die "docker 不可用(daemon 未启动或当前用户无权限)"
	if docker compose version >/dev/null 2>&1; then
		COMPOSE_V2=1
	elif command -v docker-compose >/dev/null 2>&1; then
		COMPOSE_V2=0
	else
		die "未找到 docker compose / docker-compose"
	fi
}

require_env_file() {
	[ -f "$ENV_FILE" ] || die "未找到 $ENV_FILE(用 BG_ENV_FILE 指定现有部署的 .env)"
}

require_init() {
	[ -f "$STATE_FILE" ] || die "尚未初始化,先运行: $0 init"
	[ -f "$MOUNT_FILE" ] || die "缺少 $MOUNT_FILE,重新运行: $0 init --force"
	docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1 || die "edge 容器不存在,先运行: $0 init"
	[ "$(docker inspect -f '{{.State.Running}}' "$EDGE_CONTAINER" 2>/dev/null || true)" = "true" ] ||
		die "edge 容器未运行,先执行: docker start $EDGE_CONTAINER"
}

run_compose() {
	if [ "$COMPOSE_V2" -eq 1 ]; then
		docker compose "$@"
	else
		docker-compose "$@"
	fi
}

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
reset_state_vars() {
	ACTIVE=""
	PREVIOUS=""
	IMAGE_BLUE=""
	IMAGE_GREEN=""
	BG_NETWORK=""
	BG_DATA_TYPE=""
	BG_DATA_SOURCE=""
	BG_EDGE_PORT="8080"
	BG_EDGE_BIND_IP="0.0.0.0"
	BG_BLUE_PORT="18080"
	BG_GREEN_PORT="18081"
	BG_BIND_IP="127.0.0.1"
	BG_TRUSTED_PROXIES=""
}

load_state() {
	reset_state_vars
	[ -f "$STATE_FILE" ] || return 0
	# shellcheck disable=SC1090
	. "$STATE_FILE"
	if [ -z "${BG_NETWORK:-}" ]; then
		die "$STATE_FILE 缺少 BG_NETWORK,重新运行: $0 init --force"
	fi
}

save_state() {
	mkdir -p "$RUNTIME_DIR"
	local tmp="$STATE_FILE.tmp.$$"
	{
		printf 'ACTIVE=%q\n' "${ACTIVE:-}"
		printf 'PREVIOUS=%q\n' "${PREVIOUS:-}"
		printf 'IMAGE_BLUE=%q\n' "${IMAGE_BLUE:-}"
		printf 'IMAGE_GREEN=%q\n' "${IMAGE_GREEN:-}"
		printf 'BG_NETWORK=%q\n' "${BG_NETWORK:-}"
		printf 'BG_DATA_TYPE=%q\n' "${BG_DATA_TYPE:-}"
		printf 'BG_DATA_SOURCE=%q\n' "${BG_DATA_SOURCE:-}"
		printf 'BG_EDGE_PORT=%q\n' "${BG_EDGE_PORT:-8080}"
		printf 'BG_EDGE_BIND_IP=%q\n' "${BG_EDGE_BIND_IP:-0.0.0.0}"
		printf 'BG_BLUE_PORT=%q\n' "${BG_BLUE_PORT:-18080}"
		printf 'BG_GREEN_PORT=%q\n' "${BG_GREEN_PORT:-18081}"
		printf 'BG_BIND_IP=%q\n' "${BG_BIND_IP:-127.0.0.1}"
		printf 'BG_TRUSTED_PROXIES=%q\n' "${BG_TRUSTED_PROXIES:-}"
	} >"$tmp"
	mv "$tmp" "$STATE_FILE"
}

export_bg_env() {
	export BG_NETWORK BG_BIND_IP BG_TRUSTED_PROXIES
	export BG_EDGE_PORT BG_EDGE_BIND_IP BG_BLUE_PORT BG_GREEN_PORT

	# The app must trust the edge container's network for X-Forwarded-* parsing.
	# Precedence: shell > .env > detected subnet.
	if [ -z "${SERVER_TRUSTED_PROXIES:-}" ] && [ -z "$(env_value SERVER_TRUSTED_PROXIES || true)" ]; then
		export SERVER_TRUSTED_PROXIES="${BG_TRUSTED_PROXIES:-}"
	fi
}

# -----------------------------------------------------------------------------
# Slot helpers
# -----------------------------------------------------------------------------
slot_port() {
	case "$1" in
	blue) printf '%s\n' "$BG_BLUE_PORT" ;;
	green) printf '%s\n' "$BG_GREEN_PORT" ;;
	*) die "未知槽位: $1(只能是 blue 或 green)" ;;
	esac
}

other_slot() {
	case "$1" in
	blue) printf 'green\n' ;;
	green) printf 'blue\n' ;;
	*) printf 'blue\n' ;;
	esac
}

image_for_slot() {
	case "$1" in
	blue) printf '%s\n' "$IMAGE_BLUE" ;;
	green) printf '%s\n' "$IMAGE_GREEN" ;;
	esac
}

slot_container() { printf '%s-%s\n' "$SLOT_PREFIX" "$1"; }

slot_running() {
	[ "$(docker inspect -f '{{.State.Running}}' "$(slot_container "$1")" 2>/dev/null || true)" = "true" ]
}

slot_health() {
	local out
	out="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$(slot_container "$1")" 2>/dev/null || true)"
	[ -n "$out" ] || out="-"
	printf '%s\n' "$out"
}

app_compose() {
	local slot="$1"
	shift
	export BG_SLOT="$slot"
	export BG_IMAGE="${BG_IMAGE_RUN:-$DEFAULT_IMAGE}"
	export BG_HOST_PORT
	BG_HOST_PORT="$(slot_port "$slot")"
	run_compose --env-file "$ENV_FILE" -p "$SLOT_PREFIX-$slot" -f "$COMPOSE_FILE" -f "$MOUNT_FILE" "$@"
}

edge_compose() {
	run_compose --env-file "$ENV_FILE" -p "$EDGE_PROJECT" -f "$COMPOSE_FILE" "$@"
}

# -----------------------------------------------------------------------------
# Detection (existing single-container deployment)
# -----------------------------------------------------------------------------
detect_legacy_container() {
	if docker inspect "$LEGACY_CONTAINER" >/dev/null 2>&1; then
		printf '%s\n' "$LEGACY_CONTAINER"
		return 0
	fi
	docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null |
		awk -F'\t' '$2 ~ /sub2api/ { print $1; exit }'
}

detect_network_from_container() {
	local container="$1" nets n
	nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$container" 2>/dev/null || true)"
	for n in $nets; do
		case "$n" in
		*sub2api-network*) printf '%s\n' "$n"; return 0 ;;
		esac
	done
	printf '%s\n' "$nets" | awk 'NF { print $1; exit }'
}

detect_network_any() {
	docker network ls --format '{{.Name}}' 2>/dev/null | awk '/sub2api-network$/ { print; exit }'
}

detect_data_mount() {
	local container="$1"
	docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Type}}|{{if eq .Type "bind"}}{{.Source}}{{else}}{{.Name}}{{end}}{{end}}{{end}}' "$container" 2>/dev/null || true
}

detect_edge_port() {
	local container="$1" mapping
	mapping="$(docker port "$container" 8080/tcp 2>/dev/null | head -n 1 || true)"
	[ -n "$mapping" ] || return 0
	printf '%s\n' "${mapping##*:}"
}

detect_subnets() {
	local network="$1"
	docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$network" 2>/dev/null |
		awk '{ for (i = 1; i <= NF; i++) printf "%s%s", (i > 1 ? "," : ""), $i; print "" }'
}

# An image reference that can never move to a different build.
is_immutable_ref() {
	case "$1" in
	*@sha256:* | sha256:*) return 0 ;;
	esac
	return 1
}

# Pin the exact image the legacy container is running. Using its tag directly
# would re-resolve ":latest" and silently promote the slot to a newer build than
# the one currently serving traffic.
resolve_legacy_image() {
	local container="$1" id digest
	id="$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true)"
	[ -n "$id" ] || return 0
	digest="$(docker image inspect -f '{{index .RepoDigests 0}}' "$id" 2>/dev/null || true)"
	if [ -n "$digest" ] && [ "$digest" != "<no value>" ]; then
		printf '%s\n' "$digest"
		return 0
	fi
	printf '%s\n' "$id"
}

detect_all() {
	local legacy="$1" mount type source
	reset_state_vars

	if [ -n "$legacy" ]; then
		BG_NETWORK="$(detect_network_from_container "$legacy")"
		mount="$(detect_data_mount "$legacy")"
		if [ -n "$mount" ]; then
			type="${mount%%|*}"
			source="${mount#*|}"
			BG_DATA_TYPE="$type"
			BG_DATA_SOURCE="$source"
		fi
		local port
		port="$(detect_edge_port "$legacy")"
		[ -n "$port" ] && BG_EDGE_PORT="$port"
		BG_TRUSTED_PROXIES="$(detect_subnets "${BG_NETWORK:-}")"
	fi

	[ -n "${BG_NETWORK:-}" ] || BG_NETWORK="$(detect_network_any || true)"
	[ -n "${BG_NETWORK:-}" ] || BG_NETWORK="sub2api-network"

	if [ -z "${BG_DATA_TYPE:-}" ]; then
		if [ -d "$DEPLOY_DIR/data" ]; then
			BG_DATA_TYPE="bind"
			BG_DATA_SOURCE="$DEPLOY_DIR/data"
		else
			BG_DATA_TYPE="volume"
			BG_DATA_SOURCE="$(docker volume ls --format '{{.Name}}' 2>/dev/null | awk '/sub2api_data$/ { print; exit }')"
			[ -n "$BG_DATA_SOURCE" ] || die "无法确定应用数据目录:未找到 $DEPLOY_DIR/data,也没有名为 *sub2api_data 的卷"
		fi
	fi

	[ -n "${BG_TRUSTED_PROXIES:-}" ] || BG_TRUSTED_PROXIES="$(detect_subnets "${BG_NETWORK:-}")"
}

# -----------------------------------------------------------------------------
# Data mount override (bind or named volume, decided at init time)
# -----------------------------------------------------------------------------
render_mount() {
	local type="$1" source="$2" key
	[ -n "$type" ] || die "render-mount 需要类型(bind|volume)"
	[ -n "$source" ] || die "render-mount 需要 source"
	case "$type" in
	bind)
		printf '# Generated by bluegreen.sh. Do not edit.\n'
		printf 'services:\n'
		printf '  app:\n'
		printf '    volumes:\n'
		printf '      - "%s:/app/data:Z"\n' "$source"
		;;
	volume)
		printf '# Generated by bluegreen.sh. Do not edit.\n'
		printf 'services:\n'
		printf '  app:\n'
		printf '    volumes:\n'
		printf '      - type: volume\n'
		printf '        source: bg_data\n'
		printf '        target: /app/data\n'
		printf 'volumes:\n'
		printf '  bg_data:\n'
		printf '    external: true\n'
		printf '    name: "%s"\n' "$source"
		;;
	*)
		die "未知的数据挂载类型: $type(只能是 bind 或 volume)"
		;;
	esac
}

write_mount_file() {
	local tmp="$MOUNT_FILE.tmp.$$"
	render_mount "$BG_DATA_TYPE" "$BG_DATA_SOURCE" >"$tmp"
	mv "$tmp" "$MOUNT_FILE"
}

# -----------------------------------------------------------------------------
# Upstream file + edge reload
# -----------------------------------------------------------------------------
write_upstream() {
	local primary="$1" standby="${2:-}" line tmp
	line="to sub2api-$primary:8080"
	if [ -n "$standby" ] && slot_running "$standby"; then
		line="$line sub2api-$standby:8080"
	fi
	tmp="$UPSTREAM_FILE.tmp.$$"
	{
		printf '# Managed by bluegreen.sh. Do not edit.\n'
		printf '# Generated at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf '%s\n' "$line"
	} >"$tmp"
	mv "$tmp" "$UPSTREAM_FILE"
	info "上游顺序: $line"
}

reload_edge() {
	local attempt=1 out
	while [ "$attempt" -le 3 ]; do
		if out="$(docker exec "$EDGE_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
			info "edge 配置已热加载"
			return 0
		fi
		printf '%s\n' "$out" >&2
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

verify_public() {
	local host="127.0.0.1" url attempt=1
	case "${BG_EDGE_BIND_IP:-}" in
	"" | 0.0.0.0 | "::" | "[::]") host="127.0.0.1" ;;
	*) host="$BG_EDGE_BIND_IP" ;;
	esac
	url="http://$host:$BG_EDGE_PORT/health"

	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		warn "宿主机没有 curl/wget,跳过入口校验"
		return 0
	fi

	while [ "$attempt" -le 3 ]; do
		if command -v curl >/dev/null 2>&1; then
			curl -fsS -m 5 "$url" >/dev/null 2>&1 && {
				info "入口校验通过: $url"
				return 0
			}
		else
			wget -q -T 5 -O /dev/null "$url" 2>/dev/null && {
				info "入口校验通过: $url"
				return 0
			}
		fi
		sleep 1
		attempt=$((attempt + 1))
	done

	warn "入口校验失败: $url"
	return 1
}

# -----------------------------------------------------------------------------
# Readiness
# -----------------------------------------------------------------------------
wait_ready() {
	local slot="$1" timeout="${2:-$HEALTH_TIMEOUT}" name start now elapsed exited=0 tick=0
	name="$(slot_container "$slot")"
	start="$(date +%s)"
	info "等待 $slot 就绪(最多 ${timeout}s;首次启动会先跑数据库迁移)..."

	while :; do
		if ! docker inspect "$name" >/dev/null 2>&1; then
			die "容器 $name 不存在"
		fi
		now="$(date +%s)"
		elapsed=$((now - start))

		if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)" = "true" ]; then
			exited=0
			if docker exec "$name" wget -q -T 3 -O /dev/null http://127.0.0.1:8080/health >/dev/null 2>&1; then
				info "$slot 就绪(耗时 ${elapsed}s)"
				return 0
			fi
		else
			exited=$((exited + 1))
			if [ "$exited" -ge 3 ]; then
				warn "$name 反复退出,最近日志:"
				docker logs --tail 100 "$name" >&2 || true
				die "容器无法保持运行,放弃切换(当前流量未受影响)"
			fi
		fi

		if [ "$elapsed" -ge "$timeout" ]; then
			warn "$slot 在 ${timeout}s 内未就绪,最近日志:"
			docker logs --tail 100 "$name" >&2 || true
			die "放弃切换(当前流量未受影响)"
		fi

		tick=$((tick + 3))
		if [ "$tick" -ge 30 ]; then
			tick=0
			info "仍在等待 $slot... ${elapsed}s"
		fi
		sleep 3
	done
}

# -----------------------------------------------------------------------------
# Cutover with automatic revert
# -----------------------------------------------------------------------------
cutover() {
	local target="$1" from="$2"
	write_upstream "$target" "$from"
	if ! reload_edge; then
		warn "edge 热加载失败,恢复原上游 $from"
		write_upstream "$from" "$target"
		reload_edge || warn "edge 恢复失败,请立即检查: docker logs $EDGE_CONTAINER"
		die "切换失败,流量仍在 $from"
	fi
	if ! verify_public; then
		warn "入口校验失败,自动回滚到 $from"
		write_upstream "$from" "$target"
		reload_edge || warn "edge 回滚失败,请立即检查: docker logs $EDGE_CONTAINER"
		die "已回滚到 $from;$target 保持运行以便排查: $0 logs $target"
	fi
}

# -----------------------------------------------------------------------------
# Secrets preflight
# -----------------------------------------------------------------------------
env_value() {
	local key="$1"
	awk -v k="$key" '
		{
			line = $0
			sub(/^[[:space:]]+/, "", line)
			sub(/^export[[:space:]]+/, "", line)
			if (index(line, k "=") == 1) {
				v = substr(line, length(k) + 2)
				sub(/[[:space:]]+$/, "", v)
				gsub(/^"|"$/, "", v)
				print v
				exit
			}
		}
	' "$ENV_FILE" 2>/dev/null | head -n 1
}

check_env_secrets() {
	local totp jwt
	totp="$(env_value TOTP_ENCRYPTION_KEY)"
	jwt="$(env_value JWT_SECRET)"

	if [ -z "$totp" ]; then
		die "TOTP_ENCRYPTION_KEY 为空。蓝绿两个实例必须使用同一把密钥,否则无法互相解密 2FA 与凭证密文。请使用现有部署已经在用的那把密钥(openssl rand -hex 32);注意如果老部署一直是随机生成的,原有 2FA 数据本就无法跨重启解密,换固定密钥不会额外丢失数据。"
	fi
	if [ "${#totp}" -lt 32 ]; then
		die "TOTP_ENCRYPTION_KEY 太短(${#totp} 字符),至少需要 32 字符。"
	fi
	if [ -z "$jwt" ]; then
		warn "JWT_SECRET 为空:应用会把生成的 secret 落库,多实例仍一致,但建议显式设置。"
	fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_init() {
	local force=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--force) force=1 ;;
		-h | --help) usage; exit 0 ;;
		*) die "未知参数: $1" ;;
		esac
		shift
	done

	require_docker
	require_env_file
	if [ -f "$STATE_FILE" ] && [ "$force" -eq 0 ]; then
		die "已经初始化过($STATE_FILE 存在)。要重新检测环境: $0 init --force"
	fi

	# --force on an initialized deployment only refreshes the detected values
	# (network, data mount, ports). Rebuilding the slots here would move traffic
	# around, which is exactly what `deploy` / `rollback` are for.
	if [ -f "$STATE_FILE" ] && [ "$force" -eq 1 ]; then
		local saved_active saved_previous saved_blue saved_green
		info "已初始化:仅重新检测环境,不重建容器"
		load_state
		saved_active="$ACTIVE"
		saved_previous="$PREVIOUS"
		saved_blue="$IMAGE_BLUE"
		saved_green="$IMAGE_GREEN"
		detect_all "$(detect_legacy_container)"
		ACTIVE="$saved_active"
		PREVIOUS="$saved_previous"
		IMAGE_BLUE="$saved_blue"
		IMAGE_GREEN="$saved_green"
		check_env_secrets
		export_bg_env
		docker network inspect "$BG_NETWORK" >/dev/null 2>&1 ||
			die "网络 $BG_NETWORK 不存在,用 BG_NETWORK 指定正确的网络名"
		mkdir -p "$RUNTIME_DIR" "$RUNTIME_DIR/caddy"
		write_mount_file
		save_state
		info "已更新:网络=$BG_NETWORK 数据=$BG_DATA_TYPE:$BG_DATA_SOURCE 入口端口=$BG_EDGE_PORT"
		info "容器未重建;如果数据挂载或端口发生变化,需要手动重建槽位"
		return 0
	fi

	if docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1; then
		die "edge 容器已存在,无需重复 init(要改检测结果用 --force)"
	fi

	local legacy image
	legacy="$(detect_legacy_container)"
	info "检测到现有容器: ${legacy:-无}"
	detect_all "$legacy"
	check_env_secrets
	export_bg_env

	info "数据目录: $BG_DATA_TYPE $BG_DATA_SOURCE"
	info "网络: $BG_NETWORK"
	info "入口端口: $BG_EDGE_PORT(blue 调试端口 $BG_BLUE_PORT / green $BG_GREEN_PORT)"
	docker network inspect "$BG_NETWORK" >/dev/null 2>&1 ||
		die "网络 $BG_NETWORK 不存在;确认名字或用 BG_NETWORK 指定"
	if [ -z "${BG_TRUSTED_PROXIES:-}" ]; then
		warn "没有检测到网络子网:客户端 IP 会显示为 edge 容器地址;可在 .env 里设置 SERVER_TRUSTED_PROXIES 修正"
	fi
	mkdir -p "$RUNTIME_DIR" "$RUNTIME_DIR/caddy"
	write_mount_file

	if [ -n "$legacy" ]; then
		image="$(resolve_legacy_image "$legacy")"
	fi
	[ -n "${image:-}" ] || image="$DEFAULT_IMAGE"
	IMAGE_BLUE="$image"

	if is_immutable_ref "$image"; then
		info "沿用现有镜像(已按 digest/ID 固定,不会自己变成新版本): $image"
		docker image inspect "$image" >/dev/null 2>&1 ||
			die "本地找不到镜像 $image;先 docker pull 或改用 --image 指定标签"
	else
		info "拉取镜像: $image"
		if ! docker pull "$image" >/dev/null 2>&1; then
			warn "镜像拉取失败,继续使用本地缓存(如果存在)"
		fi
	fi

	BG_IMAGE_RUN="$image"
	info "启动 blue 槽位..."
	app_compose blue up -d --no-deps --force-recreate app
	wait_ready blue

	ACTIVE="blue"
	PREVIOUS=""
	save_state
	write_upstream blue ""

	if [ -n "$legacy" ]; then
		info "停止旧容器 $legacy,由 edge 接管端口 $BG_EDGE_PORT"
		docker update --restart=no "$legacy" >/dev/null 2>&1 || true
		docker stop "$legacy" >/dev/null 2>&1 || true
	fi

	info "启动 edge..."
	if ! edge_compose up -d --no-deps --force-recreate edge; then
		warn "edge 启动失败,恢复旧容器 $legacy"
		if [ -n "$legacy" ]; then
			docker update --restart=unless-stopped "$legacy" >/dev/null 2>&1 || true
			docker start "$legacy" >/dev/null 2>&1 || true
		fi
		die "edge 启动失败,已尝试恢复旧容器"
	fi
	sleep 2
	if ! verify_public; then
		warn "入口校验失败,尝试把流量交回旧容器"
		docker stop "$EDGE_CONTAINER" >/dev/null 2>&1 || true
		if [ -n "$legacy" ]; then
			docker update --restart=unless-stopped "$legacy" >/dev/null 2>&1 || true
			docker start "$legacy" >/dev/null 2>&1 || true
		fi
		die "初始化失败,已尝试恢复旧容器;排查: docker logs $EDGE_CONTAINER"
	fi

	info "初始化完成。当前 active=blue,入口 http://<host>:$BG_EDGE_PORT"
	info "下次升级: $0 deploy --image <新镜像标签>"
}

cmd_deploy() {
	local image="" stop_old=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--image)
			image="${2:-}"
			[ -n "$image" ] || die "--image 需要一个镜像标签"
			shift 2
			;;
		--image=*)
			image="${1#*=}"
			shift
			;;
		--stop-old)
			stop_old=300
			shift
			;;
		--stop-old=*)
			stop_old="${1#*=}"
			shift
			;;
		--keep-old)
			stop_old=""
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "未知参数: $1"
			;;
		esac
	done

	require_docker
	require_init
	check_env_secrets
	load_state
	export_bg_env

	local from="$ACTIVE" target
	if [ -z "$from" ]; then
		die "状态文件里没有 ACTIVE,重新运行: $0 init --force"
	fi
	target="$(other_slot "$from")"
	[ -n "$image" ] || image="$DEFAULT_IMAGE"
	if [ -n "$stop_old" ]; then
		case "$stop_old" in
		*[!0-9]*) die "--stop-old 需要整数秒数,例如 --stop-old=600" ;;
		esac
	fi

	info "当前 active=$from;把 $image 部署到 $target"
	docker pull "$image" || die "拉取镜像失败: $image"

	BG_IMAGE_RUN="$image"
	app_compose "$target" up -d --no-deps --force-recreate app ||
		die "启动 $target 失败,当前流量仍在 $from"
	wait_ready "$target"

	cutover "$target" "$from"

	PREVIOUS="$from"
	ACTIVE="$target"
	case "$target" in
	blue) IMAGE_BLUE="$image" ;;
	green) IMAGE_GREEN="$image" ;;
	esac
	save_state

	info "切换完成: active=$target,镜像 $image"

	if [ -n "$stop_old" ]; then
		info "${stop_old}s 后停止 $from(给在途流式请求留出排空时间)"
		sleep "$stop_old"
		docker stop "$(slot_container "$from")" >/dev/null 2>&1 || true
		write_upstream "$target" ""
		reload_edge || warn "edge 热加载失败,请检查: docker logs $EDGE_CONTAINER"
		info "已停止 $from"
	else
		info "旧槽位 $from 仍在运行但不接收新请求。确认没有在途流式请求后: $0 stop $from"
	fi
	info "回滚命令: $0 rollback"
}

cmd_rollback() {
	require_docker
	require_init
	load_state
	export_bg_env

	local from="$ACTIVE" target image=""
	if [ -z "$from" ]; then
		die "状态文件里没有 ACTIVE"
	fi
	target="${PREVIOUS:-$(other_slot "$from")}"
	[ -n "$target" ] || die "没有可回滚的槽位"
	[ "$target" != "$from" ] || die "回滚目标与当前槽位相同($from),无可执行操作"

	image="$(image_for_slot "$target")"
	if [ -z "$image" ]; then
		die "槽位 $target 没有记录镜像,无法回滚。请用: $0 deploy --image <旧标签>"
	fi

	info "从 $from 回滚到 $target(镜像 $image)"
	if ! slot_running "$target"; then
		info "$target 当前未运行,用记录镜像拉起..."
		BG_IMAGE_RUN="$image"
		app_compose "$target" up -d --no-deps --force-recreate app ||
			die "启动 $target 失败,流量仍在 $from"
		wait_ready "$target"
	fi

	cutover "$target" "$from"

	ACTIVE="$target"
	PREVIOUS="$from"
	save_state
	info "回滚完成: active=$target"
}

cmd_switch() {
	local target="${1:-}"
	[ -n "$target" ] || die "用法: $0 switch <blue|green>"
	case "$target" in blue | green) : ;; *) die "槽位只能是 blue 或 green" ;; esac

	require_docker
	require_init
	load_state
	export_bg_env

	local from="$ACTIVE"
	[ -n "$from" ] || die "状态文件里没有 ACTIVE"
	[ "$target" != "$from" ] || die "已经指向 $target"

	if ! slot_running "$target"; then
		die "槽位 $target 未运行,先执行: $0 start $target"
	fi
	if ! docker exec "$(slot_container "$target")" wget -q -T 3 -O /dev/null http://127.0.0.1:8080/health >/dev/null 2>&1; then
		die "槽位 $target 健康检查失败,拒绝切流"
	fi

	cutover "$target" "$from"
	PREVIOUS="$from"
	ACTIVE="$target"
	save_state
	info "已手动切换到 $target"
}

cmd_status() {
	require_docker
	load_state
	export_bg_env

	printf '%-8s %-10s %-10s %-40s %s\n' "槽位" "状态" "健康" "镜像" "调试端口"
	local slot state health image port
	for slot in blue green; do
		if docker inspect "$(slot_container "$slot")" >/dev/null 2>&1; then
			state="$(docker inspect -f '{{.State.Status}}' "$(slot_container "$slot")" 2>/dev/null || echo unknown)"
			health="$(slot_health "$slot")"
			image="$(docker inspect -f '{{.Config.Image}}' "$(slot_container "$slot")" 2>/dev/null || echo -)"
			port="$(slot_port "$slot")"
		else
			state="absent"
			health="-"
			image="-"
			port="$(slot_port "$slot")"
		fi
		printf '%-8s %-10s %-10s %-40s %s\n' "$slot" "$state" "$health" "$image" "$port"
	done

	printf '\nactive: %s\n' "${ACTIVE:-<未设置>}"
	printf 'previous: %s\n' "${PREVIOUS:-<无>}"
	if [ -f "$UPSTREAM_FILE" ]; then
		printf 'edge 上游: %s\n' "$(grep -v '^#' "$UPSTREAM_FILE" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')"
	fi
	if docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1; then
		printf 'edge 容器: %s (端口 %s)\n' "$(docker inspect -f '{{.State.Status}}' "$EDGE_CONTAINER" 2>/dev/null || echo unknown)" "$BG_EDGE_PORT"
	else
		printf 'edge 容器: 不存在\n'
	fi
}

cmd_start() {
	local slot="${1:-}"
	[ -n "$slot" ] || die "用法: $0 start <blue|green>"
	case "$slot" in blue | green) : ;; *) die "槽位只能是 blue 或 green" ;; esac
	require_docker
	require_init
	load_state
	export_bg_env

	local image
	image="$(image_for_slot "$slot")"
	[ -n "$image" ] || die "槽位 $slot 没有记录镜像,先用 deploy 部署一次"
	if slot_running "$slot"; then
		info "$slot 已在运行"
		return 0
	fi
	BG_IMAGE_RUN="$image"
	app_compose "$slot" up -d --no-deps --force-recreate app
	wait_ready "$slot"
	info "$slot 已启动(未切流,当前 active=${ACTIVE:-none})"
}

cmd_stop() {
	local slot="${1:-}"
	[ -n "$slot" ] || die "用法: $0 stop <blue|green>"
	case "$slot" in blue | green) : ;; *) die "槽位只能是 blue 或 green" ;; esac
	require_docker
	require_init
	load_state

	if [ -z "${ACTIVE:-}" ]; then
		die "状态文件里没有 ACTIVE,重新运行: $0 init --force"
	fi
	if [ "$slot" = "$ACTIVE" ]; then
		die "$slot 是当前 active 槽位,拒绝停止。先切到另一个槽位或执行 rollback。"
	fi
	if ! slot_running "$slot"; then
		info "$slot 未在运行"
		return 0
	fi
	# 从上游候选里移除,避免 Caddy 把流量回落到正在停止的槽位
	if [ -f "$UPSTREAM_FILE" ] && grep -q "sub2api-$slot" "$UPSTREAM_FILE"; then
		write_upstream "$ACTIVE" ""
		reload_edge || warn "edge 热加载失败,请检查: docker logs $EDGE_CONTAINER"
	fi
	docker stop "$(slot_container "$slot")" >/dev/null
	info "已停止 $slot"
}

cmd_logs() {
	local target="${1:-}"
	[ -n "$target" ] || die "用法: $0 logs <blue|green|edge> [-f]"
	shift || true
	local follow=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-f | --follow) follow="-f" ;;
		*) die "未知参数: $1" ;;
		esac
		shift
	done
	case "$target" in
	blue | green) docker logs $follow --tail 200 "$(slot_container "$target")" ;;
	edge) docker logs $follow --tail 200 "$EDGE_CONTAINER" ;;
	*) die "只能查看 blue / green / edge 的日志" ;;
	esac
}

cmd_destroy() {
	require_docker
	printf '将停止并删除 %s、sub2api-blue、sub2api-green(数据库与 Redis 不受影响)。\n' "$EDGE_CONTAINER"
	printf '确认继续?[y/N] '
	read -r answer || answer=""
	case "$answer" in
	y | Y | yes | YES) : ;;
	*) info "已取消"; return 0 ;;
	esac
	local name
	for name in "$EDGE_CONTAINER" sub2api-blue sub2api-green; do
		docker rm -f "$name" >/dev/null 2>&1 || true
	done
	info "已清理容器;状态文件保留在 $STATE_FILE(如需重置: rm -rf $RUNTIME_DIR)"
}

# -----------------------------------------------------------------------------
# Dispatcher
# -----------------------------------------------------------------------------
main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	init) cmd_init "$@" ;;
	deploy | upgrade) cmd_deploy "$@" ;;
	rollback | revert) cmd_rollback "$@" ;;
	switch) cmd_switch "$@" ;;
	status) cmd_status "$@" ;;
	start) cmd_start "$@" ;;
	stop) cmd_stop "$@" ;;
	logs) cmd_logs "$@" ;;
	destroy) cmd_destroy "$@" ;;
	render-mount)
		[ "$#" -eq 2 ] || die "用法: $0 render-mount <bind|volume> <source>"
		render_mount "$1" "$2"
		;;
	help | -h | --help) usage ;;
	*)
		usage >&2
		exit 1
		;;
	esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
