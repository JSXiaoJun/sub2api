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
LOCK_DIR="$RUNTIME_DIR/lock"

EDGE_CONTAINER="sub2api-edge"
EDGE_PROJECT="sub2api-bg"
LEGACY_CONTAINER="sub2api"
SLOT_PREFIX="sub2api"

ENV_FILE="${BG_ENV_FILE:-$DEPLOY_DIR/.env}"
DEFAULT_IMAGE="${BG_IMAGE_DEFAULT:-weishaw/sub2api:latest}"
HEALTH_TIMEOUT="${BG_HEALTH_TIMEOUT:-1800}"

# Operator overrides. They must be captured here, before the defaults below
# replace the variables of the same name. `init` and `init --force` apply them
# and persist the result; every other command works from the persisted state.
OVERRIDE_BG_NETWORK="${BG_NETWORK-}"
OVERRIDE_BG_TRUSTED_PROXIES="${BG_TRUSTED_PROXIES-}"
OVERRIDE_BG_EDGE_PORT="${BG_EDGE_PORT-}"
OVERRIDE_BG_EDGE_BIND_IP="${BG_EDGE_BIND_IP-}"
OVERRIDE_BG_BLUE_PORT="${BG_BLUE_PORT-}"
OVERRIDE_BG_GREEN_PORT="${BG_GREEN_PORT-}"
OVERRIDE_BG_BIND_IP="${BG_BIND_IP-}"
OVERRIDABLE_VARS="BG_NETWORK BG_EDGE_PORT BG_EDGE_BIND_IP BG_BLUE_PORT BG_GREEN_PORT BG_BIND_IP"

COMPOSE_V2=1
LOCK_HELD=0

# Runtime state (overwritten by load_state)
ACTIVE=""
PREVIOUS=""
IMAGE_BLUE=""
IMAGE_GREEN=""
LABEL_BLUE=""
LABEL_GREEN=""
BG_NETWORK=""
BG_DATA_TYPE=""
BG_DATA_SOURCE=""
BG_EDGE_PORT="8080"
BG_EDGE_BIND_IP="0.0.0.0"
BG_BLUE_PORT="18080"
BG_GREEN_PORT="18081"
BG_BIND_IP="127.0.0.1"
BG_TRUSTED_PROXIES=""
BG_TRUSTED_PROXIES_PINNED=""
BG_IMAGE_RUN=""
EDGE_RUNNING_BINDING=""

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
                              失败时自动撤销,可直接重新运行
                              --force  已初始化时:把状态文件与实际运行的容器对齐,
                                       并应用下面的 BG_* 覆盖(不重建容器)
  deploy [--image TAG] [--stop-old[=SECS]]
                              把镜像 TAG 部署到空闲槽位,健康检查通过后切流
                              --stop-old       切流后等待 SECS 秒(默认 300)再停旧槽位
                              --keep-old       保留旧槽位(默认行为)
  rollback                    切回上一个槽位;若它已停止会用当时固定的镜像重新拉起
  switch <blue|green>         手动切到指定槽位(必须已在运行且健康)
  status                      查看两个槽位、镜像与当前上游顺序
  start <blue|green>          启动一个已停止的槽位(不切流)
  stop <blue|green>           停止一个槽位(请确认没有在途流式请求)
  recreate-edge               用当前状态重建 edge(入口端口/监听地址/请求体上限变更后使用,
                              入口会中断几秒)
  logs <blue|green|edge> [-f] 查看日志
  destroy                     停止并删除 edge 与两个槽位容器(不碰数据库)
  render-mount <bind|volume> <source>
                              内部命令,用于测试数据挂载的 YAML 生成

每次都生效的环境变量:
  BG_ENV_FILE        现有部署的 .env 路径(默认:仓库 deploy/.env)
  BG_IMAGE_DEFAULT   默认镜像(默认:weishaw/sub2api:latest)
  BG_HEALTH_TIMEOUT  等待新槽位就绪的超时秒数(默认:1800)

只在 init / init --force 时生效并写入状态文件的环境变量:
  BG_NETWORK         覆盖自动检测的 docker 网络名
  BG_TRUSTED_PROXIES 覆盖自动检测的反向代理 CIDR(设为 auto 则恢复自动检测)
  BG_EDGE_PORT / BG_EDGE_BIND_IP              入口端口与监听地址
  BG_BLUE_PORT / BG_GREEN_PORT / BG_BIND_IP   两个槽位的本机调试端口

示例:
  ./bluegreen.sh init
  ./bluegreen.sh deploy --image weishaw/sub2api:0.2.21
  ./bluegreen.sh deploy --image weishaw/sub2api:0.2.21 --stop-old=600
  ./bluegreen.sh rollback
  BG_EDGE_PORT=8081 ./bluegreen.sh init --force && ./bluegreen.sh recreate-edge
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
	docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1 ||
		die "edge 容器不存在。重建它: $0 recreate-edge;或彻底重来: $0 destroy 之后 $0 init"
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
# Locking
# -----------------------------------------------------------------------------
# Two commands interleaving (two deploys, or a rollback racing the delayed stop
# of `deploy --stop-old`) would leave the state file, the upstream file and the
# containers disagreeing about which slot is live. mkdir is atomic everywhere,
# including macOS, which has no flock(1).
#
# $1 = how many seconds to wait for a running command to finish (default 0).
acquire_lock() {
	local wait_secs="${1:-0}" waited=0 stale_cleanups=0 holder=""
	mkdir -p "$RUNTIME_DIR"
	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
		if [ -z "$holder" ]; then
			# The holder may be between creating the directory and writing its pid.
			sleep 1
			holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
		fi
		if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
			if [ "$waited" -ge "$wait_secs" ]; then
				die "另一个 bluegreen.sh 正在运行(PID $holder),等它结束后再试;确认没有其他实例在运行时可删除 $LOCK_DIR"
			fi
			sleep 2
			waited=$((waited + 2))
			continue
		fi
		stale_cleanups=$((stale_cleanups + 1))
		if [ "$stale_cleanups" -gt 3 ]; then
			die "无法获取锁,请手动删除 $LOCK_DIR 后重试"
		fi
		warn "清理残留的锁(PID ${holder:-未知} 已不存在)"
		rm -f "$LOCK_DIR/pid" 2>/dev/null || true
		rmdir "$LOCK_DIR" 2>/dev/null || true
	done
	printf '%s\n' "$$" >"$LOCK_DIR/pid"
	LOCK_HELD=1
	trap release_lock EXIT
}

release_lock() {
	[ "$LOCK_HELD" -eq 1 ] || return 0
	rm -f "$LOCK_DIR/pid" 2>/dev/null || true
	rmdir "$LOCK_DIR" 2>/dev/null || true
	LOCK_HELD=0
}

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
reset_state_vars() {
	ACTIVE=""
	PREVIOUS=""
	IMAGE_BLUE=""
	IMAGE_GREEN=""
	LABEL_BLUE=""
	LABEL_GREEN=""
	BG_NETWORK=""
	BG_DATA_TYPE=""
	BG_DATA_SOURCE=""
	BG_EDGE_PORT="8080"
	BG_EDGE_BIND_IP="0.0.0.0"
	BG_BLUE_PORT="18080"
	BG_GREEN_PORT="18081"
	BG_BIND_IP="127.0.0.1"
	BG_TRUSTED_PROXIES=""
	BG_TRUSTED_PROXIES_PINNED=""
}

read_state() {
	reset_state_vars
	[ -f "$STATE_FILE" ] || return 0
	# shellcheck disable=SC1090
	. "$STATE_FILE"
}

load_state() {
	read_state
	[ -f "$STATE_FILE" ] || return 0
	if [ -z "${BG_NETWORK:-}" ]; then
		die "$STATE_FILE 缺少 BG_NETWORK,重新运行: $0 init --force"
	fi
	warn_ignored_overrides
}

save_state() {
	mkdir -p "$RUNTIME_DIR"
	local tmp="$STATE_FILE.tmp.$$"
	{
		printf 'ACTIVE=%q\n' "${ACTIVE:-}"
		printf 'PREVIOUS=%q\n' "${PREVIOUS:-}"
		printf 'IMAGE_BLUE=%q\n' "${IMAGE_BLUE:-}"
		printf 'IMAGE_GREEN=%q\n' "${IMAGE_GREEN:-}"
		printf 'LABEL_BLUE=%q\n' "${LABEL_BLUE:-}"
		printf 'LABEL_GREEN=%q\n' "${LABEL_GREEN:-}"
		printf 'BG_NETWORK=%q\n' "${BG_NETWORK:-}"
		printf 'BG_DATA_TYPE=%q\n' "${BG_DATA_TYPE:-}"
		printf 'BG_DATA_SOURCE=%q\n' "${BG_DATA_SOURCE:-}"
		printf 'BG_EDGE_PORT=%q\n' "${BG_EDGE_PORT:-8080}"
		printf 'BG_EDGE_BIND_IP=%q\n' "${BG_EDGE_BIND_IP:-0.0.0.0}"
		printf 'BG_BLUE_PORT=%q\n' "${BG_BLUE_PORT:-18080}"
		printf 'BG_GREEN_PORT=%q\n' "${BG_GREEN_PORT:-18081}"
		printf 'BG_BIND_IP=%q\n' "${BG_BIND_IP:-127.0.0.1}"
		printf 'BG_TRUSTED_PROXIES=%q\n' "${BG_TRUSTED_PROXIES:-}"
		printf 'BG_TRUSTED_PROXIES_PINNED=%q\n' "${BG_TRUSTED_PROXIES_PINNED:-}"
	} >"$tmp"
	mv "$tmp" "$STATE_FILE"
}

apply_overrides() {
	local name var
	for name in $OVERRIDABLE_VARS; do
		var="OVERRIDE_$name"
		if [ -n "${!var}" ]; then
			printf -v "$name" '%s' "${!var}"
		fi
	done
}

# Outside init the containers already exist with the persisted values, so an
# override could only make the script disagree with what is running.
warn_ignored_overrides() {
	local name var
	for name in $OVERRIDABLE_VARS BG_TRUSTED_PROXIES; do
		var="OVERRIDE_$name"
		if [ -n "${!var}" ] && [ "${!var}" != "auto" ] && [ "${!var}" != "${!name}" ]; then
			warn "环境变量 $name=${!var} 与已保存的值(${!name:-<空>})不同,本次命令不采用;要生效请运行: $name=${!var} $0 init --force"
		fi
	done
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

label_for_slot() {
	case "$1" in
	blue) printf '%s\n' "$LABEL_BLUE" ;;
	green) printf '%s\n' "$LABEL_GREEN" ;;
	esac
}

slot_container() { printf '%s-%s\n' "$SLOT_PREFIX" "$1"; }

slot_exists() {
	docker inspect "$(slot_container "$1")" >/dev/null 2>&1
}

slot_running() {
	[ "$(docker inspect -f '{{.State.Running}}' "$(slot_container "$1")" 2>/dev/null || true)" = "true" ]
}

# Asks the application itself, from inside the container. The compose
# healthcheck lags behind by its interval and start_period.
slot_healthy() {
	docker exec "$(slot_container "$1")" wget -q -T 3 -O /dev/null http://127.0.0.1:8080/health >/dev/null 2>&1
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
# Images
# -----------------------------------------------------------------------------
# An image reference that can never move to a different build.
is_immutable_ref() {
	case "$1" in
	*@sha256:* | sha256:*) return 0 ;;
	esac
	return 1
}

# Repository part of a reference: drops the digest and the tag, keeps a
# registry port ("host:5000/app:1.2" -> "host:5000/app").
image_repo() {
	local repo="${1%@*}"
	case "${repo##*/}" in
	*:*) repo="${repo%:*}" ;;
	esac
	printf '%s\n' "$repo"
}

# Prints a repo digest of a locally present image, preferring the repository
# the operator named so the reference stays pullable from the same place.
repo_digest_of() {
	local ref="$1" want_repo="$2" digests d
	digests="$(docker image inspect -f '{{range .RepoDigests}}{{.}} {{end}}' "$ref" 2>/dev/null || true)"
	for d in $digests; do
		if [ "${d%@*}" = "$want_repo" ]; then
			printf '%s\n' "$d"
			return 0
		fi
	done
	for d in $digests; do
		printf '%s\n' "$d"
		return 0
	done
	return 1
}

# Turns a tag into the digest (or, for images that were never pushed, the
# image ID) it points at right now. Recording the tag itself would make
# `rollback` and `start` re-resolve it later and bring up whatever build the
# tag has moved to since.
pin_image() {
	local ref="$1" id
	if is_immutable_ref "$ref"; then
		printf '%s\n' "$ref"
		return 0
	fi
	repo_digest_of "$ref" "$(image_repo "$ref")" && return 0
	id="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || true)"
	[ -n "$id" ] || return 1
	printf '%s\n' "$id"
}

# Pin the exact image the legacy container is running. Using its tag directly
# would re-resolve ":latest" and silently promote the slot to a newer build than
# the one currently serving traffic.
resolve_legacy_image() {
	local container="$1" id label
	id="$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true)"
	[ -n "$id" ] || return 0
	label="$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)"
	repo_digest_of "$id" "$(image_repo "$label")" || printf '%s\n' "$id"
}

# The image a stopped slot must come back with. State files written before
# images were pinned hold a tag; the slot's own container still knows the exact
# image it was created from.
image_to_run() {
	local slot="$1" image id
	image="$(image_for_slot "$slot")"
	if [ -n "$image" ] && ! is_immutable_ref "$image"; then
		id="$(docker inspect -f '{{.Image}}' "$(slot_container "$slot")" 2>/dev/null || true)"
		if [ -n "$id" ]; then
			image="$id"
		fi
	fi
	printf '%s\n' "$image"
}

# -----------------------------------------------------------------------------
# Detection (existing single-container deployment)
# -----------------------------------------------------------------------------
detect_legacy_container() {
	if docker inspect "$LEGACY_CONTAINER" >/dev/null 2>&1; then
		printf '%s\n' "$LEGACY_CONTAINER"
		return 0
	fi
	# The slots run the same image, so they must be excluded by name or a later
	# `init --force` would mistake one of them for the legacy deployment.
	docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null |
		awk -F'\t' -v edge="$EDGE_CONTAINER" -v prefix="$SLOT_PREFIX" '
			$1 == edge || $1 == prefix "-blue" || $1 == prefix "-green" { next }
			$2 ~ /sub2api/ && found == "" { found = $1 }
			END { if (found != "") print found }
		' || true
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
	docker network ls --format '{{.Name}}' 2>/dev/null |
		awk '/sub2api-network$/ && found == "" { found = $0 } END { if (found != "") print found }' || true
}

detect_data_mount() {
	local container="$1"
	docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Type}}|{{if eq .Type "bind"}}{{.Source}}{{else}}{{.Name}}{{end}}{{end}}{{end}}' "$container" 2>/dev/null || true
}

# Prints "<host ip>:<host port>" of the published application port. Reads the
# configured binding, which is still there after the container stopped;
# `docker port` only answers for running containers.
detect_port_binding() {
	local container="$1" lines line
	lines="$(docker inspect -f '{{with index .HostConfig.PortBindings "8080/tcp"}}{{range .}}{{.HostIp}}:{{.HostPort}}{{"\n"}}{{end}}{{end}}' "$container" 2>/dev/null || true)"
	[ -n "$lines" ] || lines="$(docker port "$container" 8080/tcp 2>/dev/null || true)"
	line="$(printf '%s\n' "$lines" | awk 'NF && $0 !~ /^\[/ && found == "" { found = $0 } END { if (found != "") print found }')"
	[ -n "$line" ] || line="$(printf '%s\n' "$lines" | awk 'NF && found == "" { found = $0 } END { if (found != "") print found }')"
	printf '%s\n' "$line"
}

# The edge must listen exactly where the old container did: a deployment that
# published only on 127.0.0.1 sits behind a TLS terminator, and widening it to
# every interface would expose plain HTTP.
apply_port_binding() {
	local binding="$1" port ip
	[ -n "$binding" ] || return 0
	port="${binding##*:}"
	ip="${binding%:*}"
	case "$port" in
	"" | *[!0-9]*) return 0 ;;
	esac
	BG_EDGE_PORT="$port"
	case "$ip" in
	"" | 0.0.0.0 | "::" | "[::]") BG_EDGE_BIND_IP="0.0.0.0" ;;
	\[*\]) BG_EDGE_BIND_IP="$ip" ;;
	*:*) BG_EDGE_BIND_IP="[$ip]" ;;
	*) BG_EDGE_BIND_IP="$ip" ;;
	esac
}

detect_subnets() {
	local network="$1"
	docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$network" 2>/dev/null |
		awk '{ for (i = 1; i <= NF; i++) printf "%s%s", (i > 1 ? "," : ""), $i; print "" }' || true
}

# Shared tail of both detection paths: operator overrides win over anything
# detected, then the values that depend on them are derived.
finalize_detection() {
	local name
	apply_overrides
	[ -n "${BG_NETWORK:-}" ] || BG_NETWORK="$(detect_network_any)"
	[ -n "${BG_NETWORK:-}" ] || BG_NETWORK="sub2api-network"
	for name in BG_EDGE_PORT BG_BLUE_PORT BG_GREEN_PORT; do
		case "${!name}" in
		"" | *[!0-9]*) die "$name 必须是端口号,当前值: ${!name:-<空>}" ;;
		esac
	done
	# A CIDR list given by the operator stays until it is replaced, or handed
	# back to detection with BG_TRUSTED_PROXIES=auto; a detected one is refreshed.
	if [ -n "$OVERRIDE_BG_TRUSTED_PROXIES" ] && [ "$OVERRIDE_BG_TRUSTED_PROXIES" != "auto" ]; then
		BG_TRUSTED_PROXIES="$OVERRIDE_BG_TRUSTED_PROXIES"
		BG_TRUSTED_PROXIES_PINNED=1
	elif [ "$OVERRIDE_BG_TRUSTED_PROXIES" = "auto" ] || [ "$BG_TRUSTED_PROXIES_PINNED" != "1" ] || [ -z "$BG_TRUSTED_PROXIES" ]; then
		BG_TRUSTED_PROXIES="$(detect_subnets "$BG_NETWORK")"
		BG_TRUSTED_PROXIES_PINNED=""
	fi
}

# First-time detection, from the legacy single-container deployment.
detect_all() {
	local legacy="$1" mount
	reset_state_vars

	if [ -n "$legacy" ]; then
		BG_NETWORK="$(detect_network_from_container "$legacy")"
		mount="$(detect_data_mount "$legacy")"
		if [ -n "$mount" ]; then
			BG_DATA_TYPE="${mount%%|*}"
			BG_DATA_SOURCE="${mount#*|}"
		fi
		apply_port_binding "$(detect_port_binding "$legacy")"
	fi

	if [ -z "${BG_DATA_TYPE:-}" ]; then
		if [ -d "$DEPLOY_DIR/data" ]; then
			BG_DATA_TYPE="bind"
			BG_DATA_SOURCE="$DEPLOY_DIR/data"
		else
			BG_DATA_TYPE="volume"
			BG_DATA_SOURCE="$(docker volume ls --format '{{.Name}}' 2>/dev/null |
				awk '/sub2api_data$/ && found == "" { found = $0 } END { if (found != "") print found }' || true)"
			[ -n "$BG_DATA_SOURCE" ] || die "无法确定应用数据目录:未找到 $DEPLOY_DIR/data,也没有名为 *sub2api_data 的卷"
		fi
	fi

	finalize_detection
}

# `init --force`: bring the state file back in line with what is running.
# The containers are the ground truth here, not the legacy container: by now it
# is stopped or gone, and what it once published says nothing about the edge.
refresh_from_running() {
	local source="" net mount

	if [ -n "$ACTIVE" ] && slot_exists "$ACTIVE"; then
		source="$(slot_container "$ACTIVE")"
	else
		source="$(detect_legacy_container)"
	fi
	if [ -n "$source" ]; then
		net="$(detect_network_from_container "$source")"
		if [ -n "$net" ]; then
			BG_NETWORK="$net"
		fi
		mount="$(detect_data_mount "$source")"
		if [ -n "$mount" ]; then
			BG_DATA_TYPE="${mount%%|*}"
			BG_DATA_SOURCE="${mount#*|}"
		fi
	fi
	EDGE_RUNNING_BINDING=""
	if docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1; then
		apply_port_binding "$(detect_port_binding "$EDGE_CONTAINER")"
		EDGE_RUNNING_BINDING="$BG_EDGE_BIND_IP:$BG_EDGE_PORT"
	fi

	finalize_detection
}

# -----------------------------------------------------------------------------
# Data mount override (bind or named volume, decided at init time)
# -----------------------------------------------------------------------------
render_mount() {
	local type="$1" source="$2"
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
	local host="127.0.0.1" port url attempt=1
	local saved_ip="$BG_EDGE_BIND_IP" saved_port="$BG_EDGE_PORT"
	# Ask the edge where it really listens. After `init --force` changed the
	# entry settings and before `recreate-edge`, the persisted values describe
	# the next edge, and checking them would fail every cutover.
	apply_port_binding "$(detect_port_binding "$EDGE_CONTAINER")"
	port="$BG_EDGE_PORT"
	case "${BG_EDGE_BIND_IP:-}" in
	"" | 0.0.0.0 | "::" | "[::]") host="127.0.0.1" ;;
	*) host="$BG_EDGE_BIND_IP" ;;
	esac
	BG_EDGE_BIND_IP="$saved_ip"
	BG_EDGE_PORT="$saved_port"
	url="http://$host:$port/health"

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
# Returns non-zero instead of exiting: the caller decides what to do with a
# slot that never came up.
wait_ready() {
	local slot="$1" timeout="${2:-$HEALTH_TIMEOUT}" name start now elapsed exited=0 tick=0
	name="$(slot_container "$slot")"
	start="$(date +%s)"
	info "等待 $slot 就绪(最多 ${timeout}s;首次启动会先跑数据库迁移)..."

	while :; do
		if ! docker inspect "$name" >/dev/null 2>&1; then
			warn "容器 $name 不存在"
			return 1
		fi
		now="$(date +%s)"
		elapsed=$((now - start))

		if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)" = "true" ]; then
			exited=0
			if slot_healthy "$slot"; then
				info "$slot 就绪(耗时 ${elapsed}s)"
				return 0
			fi
		else
			exited=$((exited + 1))
			if [ "$exited" -ge 3 ]; then
				warn "$name 反复退出,最近日志:"
				docker logs --tail 100 "$name" >&2 || true
				return 1
			fi
		fi

		if [ "$elapsed" -ge "$timeout" ]; then
			warn "$slot 在 ${timeout}s 内未就绪,最近日志:"
			docker logs --tail 100 "$name" >&2 || true
			return 1
		fi

		tick=$((tick + 3))
		if [ "$tick" -ge 30 ]; then
			tick=0
			info "仍在等待 $slot... ${elapsed}s"
		fi
		sleep 3
	done
}

# A slot that failed to come up keeps restarting under `restart:
# unless-stopped`, re-running migrations each time. Stop it; `logs` still works.
stop_failed_slot() {
	docker stop "$(slot_container "$1")" >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Cutover with automatic revert
# -----------------------------------------------------------------------------
cutover() {
	local target="$1" from="$2"
	# The entry check below cannot stand in for this: with a dead primary Caddy
	# answers from the standby, and the entry still looks fine.
	slot_healthy "$target" ||
		die "槽位 $target 健康检查失败,拒绝切流(流量仍在 $from)。排查: $0 logs $target"
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

# Takes a non-active slot out of the upstream list before stopping it, so
# Caddy cannot fail over to a container that is shutting down.
retire_slot() {
	local slot="$1"
	if [ -f "$UPSTREAM_FILE" ] && grep -q "sub2api-$slot" "$UPSTREAM_FILE"; then
		write_upstream "$ACTIVE" ""
		reload_edge || warn "edge 热加载失败,请检查: docker logs $EDGE_CONTAINER"
	fi
	docker stop "$(slot_container "$slot")" >/dev/null
}

# -----------------------------------------------------------------------------
# Environment preflight
# -----------------------------------------------------------------------------
# Value of KEY in the env file, read the way compose reads it: the last
# assignment wins, matching quotes are removed, and an unquoted value ends at
# " #".
env_value() {
	local key="$1"
	[ -f "$ENV_FILE" ] || return 0
	awk -v k="$key" -v sq="'" '
		{
			line = $0
			sub(/\r$/, "", line)
			sub(/^[[:space:]]+/, "", line)
			sub(/^export[[:space:]]+/, "", line)
			if (index(line, k "=") != 1) next
			v = substr(line, length(k) + 2)
			q = substr(v, 1, 1)
			if (q == "\"" || q == sq) {
				rest = substr(v, 2)
				close_at = index(rest, q)
				v = (close_at > 0) ? substr(rest, 1, close_at - 1) : rest
			} else {
				sub(/[[:space:]]+#.*$/, "", v)
				sub(/[[:space:]]+$/, "", v)
			}
			found = 1
			value = v
		}
		END { if (found) print value }
	' "$ENV_FILE"
}

# What the containers will actually receive: compose lets the shell
# environment win over --env-file.
effective_env() {
	local key="$1" value
	value="$(printenv "$key" 2>/dev/null || true)"
	if [ -n "$value" ]; then
		printf '%s\n' "$value"
	else
		env_value "$key"
	fi
}

check_env_secrets() {
	local totp jwt
	totp="$(effective_env TOTP_ENCRYPTION_KEY)"
	jwt="$(effective_env JWT_SECRET)"

	if [ -z "$totp" ]; then
		die "TOTP_ENCRYPTION_KEY 为空。蓝绿两个实例必须使用同一把密钥,否则无法互相解密 2FA 与凭证密文。请填入现有部署已经在用的那把密钥;如果老部署一直留空(每次启动随机生成),原有 2FA 数据本就无法跨重启解密,此时用 openssl rand -hex 32 新生成一把即可,不会额外丢失数据。"
	fi
	# The application decodes the key as hex and requires exactly 32 bytes;
	# anything else makes the new slot exit during startup.
	case "$totp" in
	*[!0-9a-fA-F]*) die "TOTP_ENCRYPTION_KEY 必须是 64 位十六进制字符(openssl rand -hex 32 的输出),当前值含有其他字符。" ;;
	esac
	if [ "${#totp}" -ne 64 ]; then
		die "TOTP_ENCRYPTION_KEY 必须是 64 位十六进制字符(openssl rand -hex 32 的输出),当前是 ${#totp} 位。"
	fi
	if [ -z "$jwt" ]; then
		warn "JWT_SECRET 为空:应用会把生成的 secret 落库,多实例仍一致,但建议显式设置。"
	fi
}

# max_connections as the bundled PostgreSQL container reports it; prints nothing
# when the database runs elsewhere or cannot be asked.
detect_pg_max_connections() {
	local container="$SLOT_PREFIX-postgres" user db out
	[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = "true" ] || return 0
	user="$(effective_env POSTGRES_USER)"
	db="$(effective_env POSTGRES_DB)"
	out="$(docker exec "$container" psql -U "${user:-sub2api}" -d "${db:-sub2api}" -Atc 'show max_connections' 2>/dev/null || true)"
	case "$out" in
	"" | *[!0-9]*) return 0 ;;
	esac
	printf '%s\n' "$out"
}

# Both slots keep their own connection pool while they overlap.
check_db_connections() {
	local per_slot max assumed=""
	per_slot="$(effective_env DATABASE_MAX_OPEN_CONNS)"
	[ -n "$per_slot" ] || per_slot=50
	# The database is the authority: POSTGRES_MAX_CONNECTIONS in .env only takes
	# effect when the compose file in use passes it on to postgres.
	max="$(detect_pg_max_connections)"
	if [ -z "$max" ]; then
		max="$(effective_env POSTGRES_MAX_CONNECTIONS)"
		assumed="(取自 .env 的 POSTGRES_MAX_CONNECTIONS,未能向数据库确认)"
	fi
	if [ -z "$max" ]; then
		max=100
		assumed="(未能向数据库确认,按 PostgreSQL 默认值 100 估算)"
	fi
	case "$per_slot$max" in
	*[!0-9]*) return 0 ;;
	esac
	# PostgreSQL keeps 3 connections back for superusers by default.
	if [ $((per_slot * 2)) -gt $((max - 3)) ]; then
		warn "两个槽位并存时最多会打开 $((per_slot * 2)) 个数据库连接(DATABASE_MAX_OPEN_CONNS=$per_slot × 2),超过 PostgreSQL 的可用上限 $((max - 3))$assumed。请调大 POSTGRES_MAX_CONNECTIONS 或调小 DATABASE_MAX_OPEN_CONNS,否则两个槽位同时繁忙时会出现 too many clients。"
	fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
# Prints "<pinned image>|<label>" of the slot that was active when `destroy`
# last ran, or nothing.
destroyed_active_image() {
	local file="$STATE_FILE.destroyed"
	[ -f "$file" ] || return 0
	(
		ACTIVE="" IMAGE_BLUE="" IMAGE_GREEN="" LABEL_BLUE="" LABEL_GREEN=""
		# shellcheck disable=SC1090
		. "$file"
		case "$ACTIVE" in
		blue) printf '%s|%s\n' "$IMAGE_BLUE" "$LABEL_BLUE" ;;
		green) printf '%s|%s\n' "$IMAGE_GREEN" "$LABEL_GREEN" ;;
		esac
	)
}

# Undo a first-time init that failed after the legacy container was stopped.
# Nothing is persisted before the edge is verified, so afterwards the host is
# back to the single-container deployment and `init` can simply be run again.
abort_init() {
	local legacy="$1" legacy_restart="$2" reason="$3" restored=1
	warn "$reason;撤销本次初始化"
	if docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1; then
		docker logs --tail 50 "$EDGE_CONTAINER" >&2 || true
		docker rm -f "$EDGE_CONTAINER" >/dev/null 2>&1 || true
	fi
	if [ -n "$legacy" ]; then
		docker update --restart="${legacy_restart:-unless-stopped}" "$legacy" >/dev/null 2>&1 || true
		docker start "$legacy" >/dev/null 2>&1 || restored=0
	fi
	docker rm -f "$(slot_container blue)" >/dev/null 2>&1 || true
	rm -f "$UPSTREAM_FILE"
	if [ "$restored" -eq 0 ]; then
		die "初始化失败,而且旧容器 $legacy 没能重新启动:入口当前无人服务,请立即执行 docker start $legacy 并查看 docker logs $legacy"
	fi
	die "初始化失败,已恢复到初始化之前的状态;排除问题后重新运行: $0 init"
}

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
	acquire_lock
	if [ -f "$STATE_FILE" ] && [ "$force" -eq 0 ]; then
		die "已经初始化过($STATE_FILE 存在)。要重新对齐环境: $0 init --force"
	fi

	# --force on an initialized deployment only refreshes the persisted values
	# (network, data mount, ports). Rebuilding the slots here would move traffic
	# around, which is exactly what `deploy` / `rollback` are for.
	if [ -f "$STATE_FILE" ] && [ "$force" -eq 1 ]; then
		info "已初始化:把状态文件与运行中的容器对齐,不重建容器"
		read_state
		refresh_from_running
		check_env_secrets
		docker network inspect "$BG_NETWORK" >/dev/null 2>&1 ||
			die "网络 $BG_NETWORK 不存在,用 BG_NETWORK 指定正确的网络名"
		mkdir -p "$RUNTIME_DIR" "$RUNTIME_DIR/caddy"
		write_mount_file
		save_state
		info "已更新:网络=$BG_NETWORK 数据=$BG_DATA_TYPE:$BG_DATA_SOURCE 入口=$BG_EDGE_BIND_IP:$BG_EDGE_PORT"
		if [ -n "$EDGE_RUNNING_BINDING" ] && [ "$EDGE_RUNNING_BINDING" != "$BG_EDGE_BIND_IP:$BG_EDGE_PORT" ]; then
			info "入口设置与正在运行的 edge($EDGE_RUNNING_BINDING)不同,执行 $0 recreate-edge 后生效"
		fi
		info "槽位未重建:网络、数据挂载、调试端口的变化在下一次 deploy 时对新槽位生效"
		return 0
	fi

	if docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1; then
		die "edge 容器已存在但没有状态文件。先清理再初始化: $0 destroy 之后 $0 init"
	fi

	local legacy image="" label="" legacy_restart="" legacy_running=0 last=""
	legacy="$(detect_legacy_container)"
	info "检测到现有容器: ${legacy:-无}"
	detect_all "$legacy"
	check_env_secrets
	check_db_connections
	export_bg_env

	info "数据目录: $BG_DATA_TYPE $BG_DATA_SOURCE"
	info "网络: $BG_NETWORK"
	info "入口: $BG_EDGE_BIND_IP:$BG_EDGE_PORT(blue 调试端口 $BG_BLUE_PORT / green $BG_GREEN_PORT)"
	docker network inspect "$BG_NETWORK" >/dev/null 2>&1 ||
		die "网络 $BG_NETWORK 不存在;确认名字或用 BG_NETWORK 指定"
	if [ -z "${BG_TRUSTED_PROXIES:-}" ]; then
		warn "没有检测到网络子网:客户端 IP 会显示为 edge 容器地址;可在 .env 里设置 SERVER_TRUSTED_PROXIES 修正"
	fi
	mkdir -p "$RUNTIME_DIR" "$RUNTIME_DIR/caddy"
	write_mount_file

	if [ -n "$legacy" ]; then
		image="$(resolve_legacy_image "$legacy")"
		label="$(docker inspect -f '{{.Config.Image}}' "$legacy" 2>/dev/null || true)"
		legacy_restart="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$legacy" 2>/dev/null || true)"
		if [ "$(docker inspect -f '{{.State.Running}}' "$legacy" 2>/dev/null || true)" = "true" ]; then
			legacy_running=1
		fi
	fi
	# A legacy container that is not running was replaced by the slots some
	# time ago: its image is the version from before the first deploy, and
	# starting that against a database migrated by later versions is a
	# downgrade. After `destroy`, the version that served last is on record.
	if [ "$legacy_running" -eq 0 ]; then
		last="$(destroyed_active_image)"
		if [ -n "${last%%|*}" ] && is_immutable_ref "${last%%|*}" && docker image inspect "${last%%|*}" >/dev/null 2>&1; then
			image="${last%%|*}"
			label="${last#*|}"
			info "沿用 destroy 之前 active 槽位的版本: ${label:-$image}"
		elif [ -n "$image" ]; then
			warn "旧容器 $legacy 已停止,将沿用它的镜像 ${label:-$image};如果它停止之后升级过,这个版本比数据库旧,初始化完成后请立即 deploy 到正确版本"
		fi
	fi
	if [ -n "$image" ]; then
		info "沿用现有镜像(已按 digest/ID 固定,不会自己变成新版本): $image"
		docker image inspect "$image" >/dev/null 2>&1 ||
			die "本地找不到镜像 $image;先 docker pull 它"
	else
		info "拉取镜像: $DEFAULT_IMAGE"
		docker pull "$DEFAULT_IMAGE" >/dev/null 2>&1 ||
			warn "镜像拉取失败,继续使用本地缓存(如果存在)"
		image="$(pin_image "$DEFAULT_IMAGE")" || die "本地没有镜像 $DEFAULT_IMAGE,拉取也失败了"
		label="$DEFAULT_IMAGE"
	fi

	BG_IMAGE_RUN="$image"
	info "启动 blue 槽位..."
	app_compose blue up -d --no-deps --force-recreate app ||
		die "启动 blue 失败,现有部署未受影响"
	if ! wait_ready blue; then
		docker rm -f "$(slot_container blue)" >/dev/null 2>&1 || true
		die "blue 未就绪,已移除它;现有部署未受影响"
	fi

	write_upstream blue ""

	if [ "$legacy_running" -eq 1 ]; then
		info "停止旧容器 $legacy,由 edge 接管 $BG_EDGE_BIND_IP:$BG_EDGE_PORT"
		docker update --restart=no "$legacy" >/dev/null 2>&1 || true
		docker stop "$legacy" >/dev/null 2>&1 || true
	else
		legacy=""
	fi

	info "启动 edge..."
	if ! edge_compose up -d --no-deps --force-recreate edge; then
		abort_init "$legacy" "$legacy_restart" "edge 启动失败"
	fi
	sleep 2
	if ! verify_public; then
		abort_init "$legacy" "$legacy_restart" "入口校验失败"
	fi

	# Only now is the deployment blue-green: persisting earlier would leave a
	# state file behind that makes a re-run of `init` refuse to start.
	ACTIVE="blue"
	PREVIOUS=""
	IMAGE_BLUE="$image"
	LABEL_BLUE="$label"
	save_state
	rm -f "$STATE_FILE.destroyed"

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
			[ -n "$stop_old" ] || die "--stop-old= 后面需要秒数,例如 --stop-old=600"
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
	case "$stop_old" in
	*[!0-9]*) die "--stop-old 需要整数秒数,例如 --stop-old=600" ;;
	esac

	require_docker
	require_env_file
	require_init
	acquire_lock
	load_state
	check_env_secrets
	check_db_connections
	export_bg_env

	local from="$ACTIVE" target pinned
	if [ -z "$from" ]; then
		die "状态文件里没有 ACTIVE,重新运行: $0 init --force"
	fi
	target="$(other_slot "$from")"
	[ -n "$image" ] || image="$DEFAULT_IMAGE"

	info "当前 active=$from;把 $image 部署到 $target"
	if ! { is_immutable_ref "$image" && docker image inspect "$image" >/dev/null 2>&1; }; then
		docker pull "$image" || die "拉取镜像失败: $image"
	fi
	pinned="$(pin_image "$image")" || die "无法确定镜像 $image 的 digest 或 ID"
	if [ "$pinned" != "$image" ]; then
		info "镜像固定为 $pinned(标签之后再移动也不影响回滚)"
	fi

	BG_IMAGE_RUN="$pinned"
	app_compose "$target" up -d --no-deps --force-recreate app ||
		die "启动 $target 失败,当前流量仍在 $from"
	if ! wait_ready "$target"; then
		stop_failed_slot "$target"
		die "$target 未就绪,已停止它;当前流量仍在 $from。日志: $0 logs $target"
	fi

	cutover "$target" "$from"

	PREVIOUS="$from"
	ACTIVE="$target"
	case "$target" in
	blue)
		IMAGE_BLUE="$pinned"
		LABEL_BLUE="$image"
		;;
	green)
		IMAGE_GREEN="$pinned"
		LABEL_GREEN="$image"
		;;
	esac
	save_state

	info "切换完成: active=$target,镜像 $image"
	info "回滚命令: $0 rollback"

	if [ -z "$stop_old" ]; then
		info "旧槽位 $from 仍在运行但不接收新请求。确认没有在途流式请求后: $0 stop $from"
		return 0
	fi

	info "${stop_old}s 后停止 $from(给在途流式请求留出排空时间)"
	# The lock is given up while waiting: a rollback must not have to wait for
	# the drain timer. Whatever happened in the meantime is re-read afterwards.
	release_lock
	sleep "$stop_old"
	acquire_lock 120
	load_state
	if [ "$ACTIVE" != "$target" ]; then
		warn "等待期间 active 已变为 ${ACTIVE:-<空>}(执行过 rollback 或 switch),不再停止 $from"
		return 0
	fi
	if ! slot_running "$from"; then
		info "$from 已经停止"
		return 0
	fi
	retire_slot "$from"
	info "已停止 $from"
}

cmd_rollback() {
	require_docker
	require_env_file
	require_init
	acquire_lock
	load_state
	export_bg_env

	local from="$ACTIVE" target image=""
	if [ -z "$from" ]; then
		die "状态文件里没有 ACTIVE"
	fi
	target="${PREVIOUS:-$(other_slot "$from")}"
	[ -n "$target" ] || die "没有可回滚的槽位"
	[ "$target" != "$from" ] || die "回滚目标与当前槽位相同($from),无可执行操作"

	if slot_running "$target"; then
		slot_healthy "$target" ||
			die "槽位 $target 正在运行但健康检查失败,拒绝切流(流量仍在 $from)。排查: $0 logs $target;要用记录的镜像重建它: 先 $0 stop $target,再 $0 rollback"
		info "从 $from 回滚到 $target"
	else
		image="$(image_to_run "$target")"
		if [ -z "$image" ]; then
			die "槽位 $target 没有记录镜像,无法回滚。请用: $0 deploy --image <旧标签>"
		fi
		if ! is_immutable_ref "$image"; then
			warn "槽位 $target 只记录了可变标签 $image,拉起的版本可能不是当时那一个"
		fi
		info "从 $from 回滚到 $target:$target 当前未运行,用记录的镜像 $image 拉起..."
		BG_IMAGE_RUN="$image"
		app_compose "$target" up -d --no-deps --force-recreate app ||
			die "启动 $target 失败,流量仍在 $from"
		if ! wait_ready "$target"; then
			stop_failed_slot "$target"
			die "$target 未就绪,已停止它;流量仍在 $from。日志: $0 logs $target"
		fi
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
	require_env_file
	require_init
	acquire_lock
	load_state
	export_bg_env

	local from="$ACTIVE"
	[ -n "$from" ] || die "状态文件里没有 ACTIVE"
	[ "$target" != "$from" ] || die "已经指向 $target"

	if ! slot_running "$target"; then
		die "槽位 $target 未运行,先执行: $0 start $target"
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
		port="$(slot_port "$slot")"
		if slot_exists "$slot"; then
			state="$(docker inspect -f '{{.State.Status}}' "$(slot_container "$slot")" 2>/dev/null || echo unknown)"
			health="$(slot_health "$slot")"
			image="$(label_for_slot "$slot")"
			[ -n "$image" ] || image="$(docker inspect -f '{{.Config.Image}}' "$(slot_container "$slot")" 2>/dev/null || echo -)"
		else
			state="absent"
			health="-"
			image="-"
		fi
		printf '%-8s %-10s %-10s %-40s %s\n' "$slot" "$state" "$health" "$image" "$port"
	done

	printf '\nactive: %s\n' "${ACTIVE:-<未设置>}"
	printf 'previous: %s\n' "${PREVIOUS:-<无>}"
	for slot in blue green; do
		image="$(image_for_slot "$slot")"
		if [ -n "$image" ]; then
			printf '%s 固定镜像: %s\n' "$slot" "$image"
		fi
	done
	if [ -f "$UPSTREAM_FILE" ]; then
		printf 'edge 上游: %s\n' "$(grep -v '^#' "$UPSTREAM_FILE" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')"
	fi
	if docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1; then
		printf 'edge 容器: %s (入口 %s:%s)\n' "$(docker inspect -f '{{.State.Status}}' "$EDGE_CONTAINER" 2>/dev/null || echo unknown)" "$BG_EDGE_BIND_IP" "$BG_EDGE_PORT"
	else
		printf 'edge 容器: 不存在\n'
	fi
}

cmd_start() {
	local slot="${1:-}"
	[ -n "$slot" ] || die "用法: $0 start <blue|green>"
	case "$slot" in blue | green) : ;; *) die "槽位只能是 blue 或 green" ;; esac
	require_docker
	require_env_file
	require_init
	acquire_lock
	load_state
	export_bg_env

	local image
	image="$(image_to_run "$slot")"
	[ -n "$image" ] || die "槽位 $slot 没有记录镜像,先用 deploy 部署一次"
	if slot_running "$slot"; then
		info "$slot 已在运行"
		return 0
	fi
	if ! is_immutable_ref "$image"; then
		warn "槽位 $slot 只记录了可变标签 $image,拉起的版本可能不是当时那一个"
	fi
	BG_IMAGE_RUN="$image"
	app_compose "$slot" up -d --no-deps --force-recreate app ||
		die "启动 $slot 失败"
	if ! wait_ready "$slot"; then
		stop_failed_slot "$slot"
		die "$slot 未就绪,已停止它。日志: $0 logs $slot"
	fi
	info "$slot 已启动(未切流,当前 active=${ACTIVE:-none})"
}

cmd_stop() {
	local slot="${1:-}"
	[ -n "$slot" ] || die "用法: $0 stop <blue|green>"
	case "$slot" in blue | green) : ;; *) die "槽位只能是 blue 或 green" ;; esac
	require_docker
	require_init
	acquire_lock
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
	# With the active slot down, Caddy is serving from this one.
	slot_healthy "$ACTIVE" ||
		die "active 槽位 $ACTIVE 当前不健康,流量很可能正由 $slot 承接,拒绝停止。先恢复 $ACTIVE,或执行: $0 switch $slot"
	retire_slot "$slot"
	info "已停止 $slot"
}

cmd_recreate_edge() {
	require_docker
	require_env_file
	[ -f "$STATE_FILE" ] || die "尚未初始化,先运行: $0 init"
	acquire_lock
	load_state
	export_bg_env

	[ -n "$ACTIVE" ] || die "状态文件里没有 ACTIVE,重新运行: $0 init --force"
	slot_healthy "$ACTIVE" ||
		die "active 槽位 $ACTIVE 不健康,拒绝重建 edge。排查: $0 logs $ACTIVE"
	mkdir -p "$RUNTIME_DIR" "$RUNTIME_DIR/caddy"
	if [ ! -f "$UPSTREAM_FILE" ]; then
		write_upstream "$ACTIVE" "$(other_slot "$ACTIVE")"
	fi

	warn "重建 edge:入口 $BG_EDGE_BIND_IP:$BG_EDGE_PORT 会中断几秒"
	edge_compose up -d --no-deps --force-recreate edge ||
		die "edge 启动失败(端口被占用?)。排查: docker logs $EDGE_CONTAINER"
	sleep 2
	verify_public || die "入口校验失败。排查: docker logs $EDGE_CONTAINER"
	info "edge 已重建,入口 $BG_EDGE_BIND_IP:$BG_EDGE_PORT"
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
	acquire_lock
	local name
	for name in "$EDGE_CONTAINER" sub2api-blue sub2api-green; do
		docker rm -f "$name" >/dev/null 2>&1 || true
	done
	# With the containers gone the state describes nothing; left in place it
	# would make the next `init` refuse to run.
	if [ -f "$STATE_FILE" ]; then
		mv -f "$STATE_FILE" "$STATE_FILE.destroyed"
	fi
	rm -f "$UPSTREAM_FILE" "$MOUNT_FILE"
	info "已清理容器与状态(旧状态备份在 $STATE_FILE.destroyed);重新接入: $0 init"
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
	recreate-edge) cmd_recreate_edge "$@" ;;
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
