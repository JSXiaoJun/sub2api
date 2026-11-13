#!/bin/bash
# =============================================================================
# Behavior tests for deploy/bluegreen/bluegreen.sh
# =============================================================================
# Runs the real script as a separate process against a fake `docker`, `curl`
# and `sleep` placed first on PATH. The fakes keep containers and images as
# directories, model the port conflict between the legacy container and the
# edge, and answer the entry check the way Caddy would with `lb_policy first`:
# from the first upstream that is running and healthy.
#
# Set BG_TEST_KEEP=1 to keep the scratch directory for inspection.
# =============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "$TEST_DIR/../bluegreen" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sub2api-bg-test.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"

cleanup() {
	if [ -z "${BG_TEST_KEEP:-}" ] && [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
		rm -rf "$TEST_ROOT"
	fi
}
trap cleanup EXIT

unset BG_ENV_FILE BG_IMAGE_DEFAULT BG_HEALTH_TIMEOUT BG_NETWORK BG_TRUSTED_PROXIES
unset BG_EDGE_PORT BG_EDGE_BIND_IP BG_BLUE_PORT BG_GREEN_PORT BG_BIND_IP BG_EDGE_IMAGE
unset TOTP_ENCRYPTION_KEY JWT_SECRET SERVER_TRUSTED_PROXIES DATABASE_MAX_OPEN_CONNS POSTGRES_MAX_CONNECTIONS

VALID_KEY="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SCENARIO=0
SCENARIO_NAME=""
OUT=""
RC=0
STDIN_TEXT=""

# -----------------------------------------------------------------------------
# Fakes
# -----------------------------------------------------------------------------
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/bin/bash
set -u
S="$FAKE_DOCKER_STATE"
printf 'docker %s\n' "$*" >>"$S/calls"

key() { printf '%s' "$1" | tr '/:@' '___'; }
cdir() { printf '%s/containers/%s' "$S" "$1"; }
cget() { cat "$(cdir "$1")/$2" 2>/dev/null || true; }
idir() { printf '%s/images/%s' "$S" "$(key "$1")"; }

cmd="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi

case "$cmd" in
info)
	exit 0
	;;
compose)
	[ "${1:-}" = "version" ] && exit 0
	service="${!#}"
	case "$service" in
	app)
		[ -e "$S/app_up_fail" ] && exit 1
		if [ ! -d "$(idir "$BG_IMAGE")" ]; then
			echo "no such image: $BG_IMAGE" >&2
			exit 1
		fi
		d="$(cdir "sub2api-$BG_SLOT")"
		rm -rf "$d"
		mkdir -p "$d"
		echo true >"$d/running"
		[ -e "$S/next_unhealthy" ] || : >"$d/healthy"
		printf '%s\n' "$BG_IMAGE" >"$d/config_image"
		cat "$(idir "$BG_IMAGE")/id" >"$d/image_id"
		printf '%s\n' "$BG_NETWORK" >"$d/network"
		printf '%s:%s\n' "$BG_BIND_IP" "$BG_HOST_PORT" >"$d/binding"
		printf '%s\n' "${SERVER_TRUSTED_PROXIES:-}" >"$d/trusted_proxies"
		echo unless-stopped >"$d/restart"
		src="$(sed -n 's|^ *- "\(.*\):/app/data:Z"$|\1|p' "$FAKE_RUNTIME/mount.yml")"
		if [ -n "$src" ]; then
			printf 'bind|%s\n' "$src" >"$d/mount"
		else
			printf 'volume|%s\n' "$(sed -n 's|^ *name: "\(.*\)"$|\1|p' "$FAKE_RUNTIME/mount.yml")" >"$d/mount"
		fi
		;;
	edge)
		[ -e "$S/edge_up_fail" ] && exit 1
		# A host port can only be published once.
		for other in "$S"/containers/*; do
			[ -d "$other" ] || continue
			[ "$(basename "$other")" = "sub2api-edge" ] && continue
			[ "$(cat "$other/running" 2>/dev/null)" = "true" ] || continue
			binding="$(cat "$other/binding" 2>/dev/null || true)"
			if [ "${binding##*:}" = "$BG_EDGE_PORT" ]; then
				echo "port is already allocated" >&2
				exit 1
			fi
		done
		d="$(cdir sub2api-edge)"
		rm -rf "$d"
		mkdir -p "$d"
		echo true >"$d/running"
		echo caddy:2-alpine >"$d/config_image"
		printf '%s:%s\n' "$BG_EDGE_BIND_IP" "$BG_EDGE_PORT" >"$d/binding"
		;;
	esac
	exit 0
	;;
inspect)
	fmt=""
	if [ "${1:-}" = "-f" ]; then
		fmt="$2"
		shift 2
	fi
	name="${1:-}"
	[ -d "$(cdir "$name")" ] || exit 1
	case "$fmt" in
	"") ;;
	*State.Running*) cget "$name" running ;;
	*State.Status*) if [ "$(cget "$name" running)" = "true" ]; then echo running; else echo exited; fi ;;
	*State.Health*) echo healthy ;;
	*RestartPolicy*) cget "$name" restart ;;
	*PortBindings*) cget "$name" binding ;;
	*NetworkSettings*) printf '%s \n' "$(cget "$name" network)" ;;
	*Mounts*) cget "$name" mount ;;
	*Config.Image*) cget "$name" config_image ;;
	*.Image*) cget "$name" image_id ;;
	esac
	exit 0
	;;
image)
	[ "${1:-}" = "inspect" ] || exit 0
	shift
	fmt=""
	if [ "${1:-}" = "-f" ]; then
		fmt="$2"
		shift 2
	fi
	d="$(idir "${1:-}")"
	[ -d "$d" ] || exit 1
	case "$fmt" in
	*RepoDigests*) cat "$d/digests" ;;
	*.Id*) cat "$d/id" ;;
	esac
	exit 0
	;;
pull)
	ref="${1:-}"
	[ -e "$S/pull_fail" ] && exit 1
	r="$S/registry/$(key "$ref")"
	if [ -d "$r" ]; then
		id="$(cat "$r/id")"
		digest="$(cat "$r/digest")"
		for k in "$ref" "$digest" "$id"; do
			mkdir -p "$(idir "$k")"
			printf '%s\n' "$id" >"$(idir "$k")/id"
			printf '%s\n' "$digest" >"$(idir "$k")/digests"
		done
		exit 0
	fi
	[ -d "$(idir "$ref")" ] && exit 0
	exit 1
	;;
exec)
	name="${1:-}"
	case "$name" in
	sub2api-edge)
		if [ -e "$S/reload_fail" ]; then
			echo "reload failed" >&2
			exit 1
		fi
		exit 0
		;;
	sub2api-postgres)
		cget "$name" max_connections
		exit 0
		;;
	*)
		if [ "$(cget "$name" running)" = "true" ] && [ -e "$(cdir "$name")/healthy" ]; then exit 0; fi
		exit 1
		;;
	esac
	;;
stop)
	[ -d "$(cdir "$1")" ] || exit 1
	echo false >"$(cdir "$1")/running"
	exit 0
	;;
start)
	[ -d "$(cdir "$1")" ] || exit 1
	[ -e "$S/start_fail" ] && exit 1
	echo true >"$(cdir "$1")/running"
	exit 0
	;;
update)
	policy="${1#--restart=}"
	[ -d "$(cdir "$2")" ] || exit 1
	printf '%s\n' "$policy" >"$(cdir "$2")/restart"
	exit 0
	;;
rm)
	shift
	for name in "$@"; do rm -rf "$(cdir "$name")"; done
	exit 0
	;;
ps)
	for d in "$S"/containers/*; do
		[ -d "$d" ] || continue
		[ "$(cat "$d/running" 2>/dev/null)" = "true" ] || continue
		printf '%s\t%s\n' "$(basename "$d")" "$(cat "$d/config_image" 2>/dev/null)"
	done
	exit 0
	;;
network)
	case "${1:-}" in
	inspect)
		shift
		fmt=""
		if [ "${1:-}" = "-f" ]; then
			fmt="$2"
			shift 2
		fi
		[ -e "$S/networks/${1:-}" ] || exit 1
		[ -n "$fmt" ] && echo "172.18.0.0/16 "
		exit 0
		;;
	ls)
		ls "$S/networks"
		exit 0
		;;
	esac
	;;
volume)
	ls "$S/volumes"
	exit 0
	;;
logs)
	exit 0
	;;
esac
exit 1
FAKE_DOCKER

cat >"$FAKE_BIN/curl" <<'FAKE_CURL'
#!/bin/bash
set -u
S="$FAKE_DOCKER_STATE"
url="${!#}"
printf 'curl %s\n' "$url" >>"$S/calls"
[ -e "$S/entry_fail" ] && exit 22

hostport="${url#http://}"
hostport="${hostport%%/*}"
edge="$S/containers/sub2api-edge"
[ "$(cat "$edge/running" 2>/dev/null)" = "true" ] || exit 7
binding="$(cat "$edge/binding" 2>/dev/null || true)"
[ "${binding##*:}" = "${hostport##*:}" ] || exit 7

# lb_policy first: the first upstream that is up answers.
for up in $(grep -v '^#' "$FAKE_RUNTIME/upstream.caddy" 2>/dev/null); do
	case "$up" in
	sub2api-*:8080)
		name="${up%:8080}"
		if [ "$(cat "$S/containers/$name/running" 2>/dev/null)" = "true" ] && [ -e "$S/containers/$name/healthy" ]; then
			exit 0
		fi
		;;
	esac
done
exit 22
FAKE_CURL

# Never actually sleeps. A file named on_sleep_<seconds> is run once in place
# of the wait: that is how a test makes something happen "meanwhile".
cat >"$FAKE_BIN/sleep" <<'FAKE_SLEEP'
#!/bin/bash
set -u
S="$FAKE_DOCKER_STATE"
printf 'sleep %s\n' "${1:-}" >>"$S/calls"
hook="$S/on_sleep_${1:-}"
if [ -f "$hook" ]; then
	mv "$hook" "$hook.done"
	/bin/bash "$hook.done"
fi
exit 0
FAKE_SLEEP

chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/curl" "$FAKE_BIN/sleep"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
fail() {
	printf 'FAIL [%s]: %s\n' "$SCENARIO_NAME" "$*" >&2
	printf -- '--- output of the last command (rc=%s) ---\n%s\n' "$RC" "$OUT" >&2
	exit 1
}

key() { printf '%s' "$1" | tr '/:@' '___'; }

scenario() {
	SCENARIO=$((SCENARIO + 1))
	SCENARIO_NAME="$1"
	ROOT="$TEST_ROOT/s$SCENARIO"
	BG="$ROOT/deploy/bluegreen/bluegreen.sh"
	RUNTIME="$ROOT/deploy/bluegreen/.runtime"
	ENV_PATH="$ROOT/deploy/.env"
	STATE="$ROOT/state"
	mkdir -p "$ROOT/deploy/bluegreen" "$STATE/containers" "$STATE/images" "$STATE/registry" "$STATE/networks" "$STATE/volumes"
	cp "$SOURCE_DIR/bluegreen.sh" "$SOURCE_DIR/docker-compose.bg.yml" "$SOURCE_DIR/Caddyfile" "$ROOT/deploy/bluegreen/"
	: >"$STATE/calls"
	: >"$STATE/networks/deploy_sub2api-network"
	export FAKE_DOCKER_STATE="$STATE" FAKE_RUNTIME="$RUNTIME"
	write_env "TOTP_ENCRYPTION_KEY=$VALID_KEY"
	publish "weishaw/sub2api:2" "sha256:id-two" "weishaw/sub2api@sha256:d-two"
	OUT=""
	RC=0
	STDIN_TEXT=""
}

write_env() {
	{
		printf 'POSTGRES_PASSWORD=secret\n'
		printf 'JWT_SECRET=jwt\n'
		local line
		for line in "$@"; do printf '%s\n' "$line"; done
	} >"$ENV_PATH"
}

# run [VAR=value ...] <bluegreen.sh arguments>; sets OUT and RC.
run() {
	local envs=()
	while [ "$#" -gt 0 ]; do
		case "$1" in
		[A-Z]*=*)
			envs+=("$1")
			shift
			;;
		*) break ;;
		esac
	done
	set +e
	OUT="$(printf '%s' "$STDIN_TEXT" | env ${envs[@]+"${envs[@]}"} PATH="$FAKE_BIN:$PATH" /bin/bash "$BG" "$@" 2>&1)"
	RC=$?
	set -e
}

ok() {
	run "$@"
	[ "$RC" -eq 0 ] || fail "expected success: $*"
}

refused() {
	run "$@"
	[ "$RC" -ne 0 ] || fail "expected a refusal: $*"
}

add_image() {
	local ref="$1" id="$2" digest="${3:-}" k d
	for k in "$ref" "$id" ${digest:+"$digest"}; do
		d="$STATE/images/$(key "$k")"
		mkdir -p "$d"
		printf '%s\n' "$id" >"$d/id"
		printf '%s\n' "$digest" >"$d/digests"
	done
}

publish() {
	local d="$STATE/registry/$(key "$1")"
	mkdir -p "$d"
	printf '%s\n' "$2" >"$d/id"
	printf '%s\n' "$3" >"$d/digest"
}

add_legacy() {
	local d="$STATE/containers/sub2api"
	add_image "weishaw/sub2api:latest" "sha256:id-one" "weishaw/sub2api@sha256:d-one"
	mkdir -p "$d"
	echo true >"$d/running"
	: >"$d/healthy"
	echo "weishaw/sub2api:latest" >"$d/config_image"
	echo "sha256:id-one" >"$d/image_id"
	echo "deploy_sub2api-network" >"$d/network"
	echo "bind|/srv/sub2api/data" >"$d/mount"
	printf '%s\n' "$1" >"$d/binding"
	echo unless-stopped >"$d/restart"
}

cfile() { cat "$STATE/containers/$1/$2" 2>/dev/null || true; }
state() { (. "$RUNTIME/state.env" && eval "printf '%s' \"\${$1-}\""); }
upstream() { grep -v '^#' "$RUNTIME/upstream.caddy"; }

eq() {
	[ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

contains() {
	case "$1" in
	*"$2"*) ;;
	*) fail "$3: expected to find '$2'" ;;
	esac
}

lacks() {
	case "$1" in
	*"$2"*) fail "$3: did not expect '$2'" ;;
	esac
}

# -----------------------------------------------------------------------------
scenario "init copies the legacy bind address and port; init --force keeps them"
# -----------------------------------------------------------------------------
add_legacy "127.0.0.1:3000"
ok init
eq "$(state ACTIVE)" "blue" "active slot"
eq "$(state BG_EDGE_PORT)" "3000" "entry port"
eq "$(state BG_EDGE_BIND_IP)" "127.0.0.1" "entry bind address"
eq "$(state IMAGE_BLUE)" "weishaw/sub2api@sha256:d-one" "blue is pinned to the legacy digest"
eq "$(state LABEL_BLUE)" "weishaw/sub2api:latest" "blue label"
eq "$(cfile sub2api-edge binding)" "127.0.0.1:3000" "edge must not widen a loopback-only entry"
eq "$(cfile sub2api running)" "false" "legacy container stopped"
eq "$(cfile sub2api restart)" "no" "legacy restart policy"
contains "$(cat "$STATE/calls")" "curl http://127.0.0.1:3000/health" "entry check target"

# The legacy container is stopped now: its port mapping is still its config.
ok init --force
eq "$(state BG_EDGE_PORT)" "3000" "entry port after init --force with a stopped legacy container"
eq "$(state BG_EDGE_BIND_IP)" "127.0.0.1" "bind address after init --force"

# With the legacy container gone, a slot must not be mistaken for it.
rm -rf "$STATE/containers/sub2api"
ok init --force
eq "$(state BG_EDGE_PORT)" "3000" "entry port after the legacy container was removed"
eq "$(state BG_NETWORK)" "deploy_sub2api-network" "network read from the active slot"
eq "$(state BG_DATA_SOURCE)" "/srv/sub2api/data" "data mount read from the active slot"
eq "$(state ACTIVE)" "blue" "init --force keeps the active slot"

# An override is applied by init --force and takes effect on the edge only
# once it is recreated; cutovers in between still check the running edge.
ok BG_EDGE_PORT=3001 init --force
eq "$(state BG_EDGE_PORT)" "3001" "override persisted"
contains "$OUT" "recreate-edge" "hint to recreate the edge"
eq "$(cfile sub2api-edge binding)" "127.0.0.1:3000" "edge untouched by init --force"
: >"$STATE/calls"
ok deploy --image weishaw/sub2api:2
contains "$(cat "$STATE/calls")" "curl http://127.0.0.1:3000/health" "cutover checks where the edge really listens"
ok recreate-edge
eq "$(cfile sub2api-edge binding)" "127.0.0.1:3001" "edge recreated on the new port"

ok BG_EDGE_PORT=4000 status
contains "$OUT" "BG_EDGE_PORT=4000" "ignored override is reported"
eq "$(state BG_EDGE_PORT)" "3001" "override outside init is not applied"

# -----------------------------------------------------------------------------
scenario "first-time init honours the documented overrides"
# -----------------------------------------------------------------------------
mkdir -p "$ROOT/deploy/data"
: >"$STATE/networks/custom-net"
publish "weishaw/sub2api:latest" "sha256:id-one" "weishaw/sub2api@sha256:d-one"
ok BG_NETWORK=custom-net BG_EDGE_PORT=9090 BG_EDGE_BIND_IP=127.0.0.1 BG_BLUE_PORT=28080 BG_TRUSTED_PROXIES=10.9.0.0/16 init
eq "$(state BG_NETWORK)" "custom-net" "network override"
eq "$(state BG_EDGE_PORT)" "9090" "entry port override"
eq "$(state BG_BLUE_PORT)" "28080" "debug port override"
eq "$(state BG_TRUSTED_PROXIES)" "10.9.0.0/16" "trusted proxies override"
eq "$(cfile sub2api-blue network)" "custom-net" "slot joined the overridden network"
eq "$(cfile sub2api-blue binding)" "127.0.0.1:28080" "slot debug port"
eq "$(cfile sub2api-blue trusted_proxies)" "10.9.0.0/16" "slot trusts the overridden CIDR"
eq "$(cfile sub2api-edge binding)" "127.0.0.1:9090" "edge entry"
eq "$(state IMAGE_BLUE)" "weishaw/sub2api@sha256:d-one" "default image is pinned"

ok init --force
eq "$(state BG_TRUSTED_PROXIES)" "10.9.0.0/16" "an operator-set CIDR survives init --force"
ok BG_TRUSTED_PROXIES=auto init --force
eq "$(state BG_TRUSTED_PROXIES)" "172.18.0.0/16" "auto goes back to the detected subnet"

# -----------------------------------------------------------------------------
scenario "a moved tag does not change what rollback and start bring up"
# -----------------------------------------------------------------------------
add_legacy "0.0.0.0:8080"
ok init
publish "weishaw/sub2api:latest" "sha256:id-two" "weishaw/sub2api@sha256:d-two"
ok deploy
eq "$(state ACTIVE)" "green" "active after first deploy"
eq "$(state IMAGE_GREEN)" "weishaw/sub2api@sha256:d-two" "green pinned to the digest behind the tag"
eq "$(state LABEL_GREEN)" "weishaw/sub2api:latest" "green label"
eq "$(cfile sub2api-green config_image)" "weishaw/sub2api@sha256:d-two" "green runs the pinned reference"
eq "$(upstream)" "to sub2api-green:8080 sub2api-blue:8080" "upstream order"

publish "weishaw/sub2api:latest" "sha256:id-three" "weishaw/sub2api@sha256:d-three"
ok deploy
eq "$(state ACTIVE)" "blue" "active after second deploy"
eq "$(state PREVIOUS)" "green" "previous after second deploy"
eq "$(cfile sub2api-blue config_image)" "weishaw/sub2api@sha256:d-three" "blue runs the new build"

ok stop green
eq "$(cfile sub2api-green running)" "false" "green stopped"
eq "$(upstream)" "to sub2api-blue:8080" "stopped slot removed from the upstreams"

ok rollback
eq "$(state ACTIVE)" "green" "rolled back"
eq "$(cfile sub2api-green config_image)" "weishaw/sub2api@sha256:d-two" "rollback restores the old build, not the tag's current one"

ok stop blue
ok start blue
eq "$(cfile sub2api-blue config_image)" "weishaw/sub2api@sha256:d-three" "start uses the pinned image"

# A state file written before images were pinned holds a tag; the slot's own
# container still knows which image it was created from.
ok stop blue
sed 's|^IMAGE_BLUE=.*|IMAGE_BLUE=weishaw/sub2api:latest|' "$RUNTIME/state.env" >"$RUNTIME/state.env.new"
mv "$RUNTIME/state.env.new" "$RUNTIME/state.env"
publish "weishaw/sub2api:latest" "sha256:id-four" "weishaw/sub2api@sha256:d-four"
ok start blue
eq "$(cfile sub2api-blue config_image)" "sha256:id-three" "tag-only state falls back to the container's image ID"

# -----------------------------------------------------------------------------
scenario "rollback and stop refuse to leave traffic on an unhealthy slot"
# -----------------------------------------------------------------------------
add_legacy "0.0.0.0:8080"
ok init
ok deploy --image weishaw/sub2api:2
eq "$(state ACTIVE)" "green" "active"

rm -f "$STATE/containers/sub2api-blue/healthy"
refused rollback
contains "$OUT" "健康检查失败" "rollback names the reason"
eq "$(state ACTIVE)" "green" "state unchanged by the refused rollback"
eq "$(upstream)" "to sub2api-green:8080 sub2api-blue:8080" "upstreams unchanged by the refused rollback"

# The active slot is down and Caddy is serving from the other one.
: >"$STATE/containers/sub2api-blue/healthy"
rm -f "$STATE/containers/sub2api-green/healthy"
refused stop blue
eq "$(cfile sub2api-blue running)" "true" "the slot carrying traffic keeps running"

ok switch blue
eq "$(state ACTIVE)" "blue" "switch to the healthy slot"
refused switch green

# -----------------------------------------------------------------------------
scenario "the delayed stop of --stop-old yields to a rollback made meanwhile"
# -----------------------------------------------------------------------------
add_legacy "0.0.0.0:8080"
ok init
cat >"$STATE/on_sleep_600" <<HOOK
/bin/bash "$BG" rollback >"$STATE/hook.log" 2>&1
echo "rc=\$?" >>"$STATE/hook.log"
HOOK
: >"$STATE/calls"
ok deploy --image weishaw/sub2api:2 --stop-old=600
contains "$(cat "$STATE/hook.log")" "rc=0" "the rollback ran while deploy was waiting"
eq "$(state ACTIVE)" "blue" "rollback result is kept"
eq "$(cfile sub2api-blue running)" "true" "the slot carrying traffic was not stopped"
lacks "$(cat "$STATE/calls")" "docker stop sub2api-blue" "no stop issued for the active slot"
eq "$(upstream)" "to sub2api-blue:8080 sub2api-green:8080" "upstreams still lead with the active slot"
[ ! -e "$RUNTIME/lock" ] || fail "lock left behind"

ok deploy --image weishaw/sub2api:2 --stop-old=5
eq "$(state ACTIVE)" "green" "active after an undisturbed deploy"
eq "$(cfile sub2api-blue running)" "false" "old slot stopped after the drain time"
eq "$(upstream)" "to sub2api-green:8080" "old slot removed from the upstreams"

# -----------------------------------------------------------------------------
scenario "a failed init restores the single-container deployment and can be re-run"
# -----------------------------------------------------------------------------
add_legacy "0.0.0.0:8080"
: >"$STATE/edge_up_fail"
refused init
[ ! -e "$RUNTIME/state.env" ] || fail "state file written by a failed init"
eq "$(cfile sub2api running)" "true" "legacy container restarted"
eq "$(cfile sub2api restart)" "unless-stopped" "legacy restart policy restored"
[ ! -d "$STATE/containers/sub2api-blue" ] || fail "blue left behind by a failed init"
rm -f "$STATE/edge_up_fail"

: >"$STATE/entry_fail"
refused init
[ ! -e "$RUNTIME/state.env" ] || fail "state file written by a failed init (entry check)"
eq "$(cfile sub2api running)" "true" "legacy container restarted after a failed entry check"
[ ! -d "$STATE/containers/sub2api-edge" ] || fail "edge left behind by a failed init"
[ ! -d "$STATE/containers/sub2api-blue" ] || fail "blue left behind by a failed init (entry check)"
rm -f "$STATE/entry_fail"

ok init
eq "$(state ACTIVE)" "blue" "init succeeds on the retry"
eq "$(cfile sub2api running)" "false" "legacy container stopped on the retry"

# -----------------------------------------------------------------------------
scenario "preflight rejects a missing env file and a key the application would reject"
# -----------------------------------------------------------------------------
add_legacy "0.0.0.0:8080"
write_env "TOTP_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef"
refused init
contains "$OUT" "64 位" "short key message"
[ ! -d "$STATE/containers/sub2api-blue" ] || fail "a slot was started with an invalid key"
eq "$(cfile sub2api running)" "true" "legacy untouched"

write_env "TOTP_ENCRYPTION_KEY=$VALID_KEY"
ok init

mv "$ENV_PATH" "$ENV_PATH.away"
refused deploy --image weishaw/sub2api:2
contains "$OUT" "未找到" "missing env file is reported"
mv "$ENV_PATH.away" "$ENV_PATH"

write_env "TOTP_ENCRYPTION_KEY=zz23456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
refused deploy --image weishaw/sub2api:2
contains "$OUT" "十六进制" "non-hex key message"
[ ! -d "$STATE/containers/sub2api-green" ] || fail "a slot was started with a non-hex key"

# Quotes and a trailing comment are how compose reads the file too.
write_env "TOTP_ENCRYPTION_KEY=\"$VALID_KEY\"   # shared by both slots"
ok deploy --image weishaw/sub2api:2
eq "$(state ACTIVE)" "green" "deploy with a quoted key"

# -----------------------------------------------------------------------------
scenario "only one command runs at a time; a stale lock is cleared"
# -----------------------------------------------------------------------------
add_legacy "0.0.0.0:8080"
ok init
mkdir -p "$RUNTIME/lock"
echo "$$" >"$RUNTIME/lock/pid"
refused deploy --image weishaw/sub2api:2
contains "$OUT" "正在运行" "lock holder is reported"
eq "$(state ACTIVE)" "blue" "nothing changed while locked"
[ ! -d "$STATE/containers/sub2api-green" ] || fail "a slot was started while locked"

echo "999999" >"$RUNTIME/lock/pid"
ok deploy --image weishaw/sub2api:2
contains "$OUT" "清理残留的锁" "stale lock is reported"
eq "$(state ACTIVE)" "green" "deploy went through after clearing the stale lock"
[ ! -e "$RUNTIME/lock" ] || fail "lock left behind"

# -----------------------------------------------------------------------------
scenario "a slot that never becomes healthy is stopped and traffic stays put"
# -----------------------------------------------------------------------------
add_legacy "0.0.0.0:8080"
ok init
: >"$STATE/next_unhealthy"
refused BG_HEALTH_TIMEOUT=0 deploy --image weishaw/sub2api:2
eq "$(cfile sub2api-green running)" "false" "the failed slot does not keep restarting"
eq "$(state ACTIVE)" "blue" "active unchanged"
eq "$(upstream)" "to sub2api-blue:8080" "upstreams unchanged"
rm -f "$STATE/next_unhealthy"

: >"$STATE/reload_fail"
refused deploy --image weishaw/sub2api:2
eq "$(state ACTIVE)" "blue" "active unchanged after a failed reload"
eq "$(upstream)" "to sub2api-blue:8080 sub2api-green:8080" "upstreams reverted after a failed reload"

# -----------------------------------------------------------------------------
scenario "two slots that can exhaust the database connections are reported"
# -----------------------------------------------------------------------------
add_legacy "0.0.0.0:8080"
write_env "TOTP_ENCRYPTION_KEY=$VALID_KEY" "DATABASE_MAX_OPEN_CONNS=256"
mkdir -p "$STATE/containers/sub2api-postgres"
echo true >"$STATE/containers/sub2api-postgres/running"
echo "postgres:18-alpine" >"$STATE/containers/sub2api-postgres/config_image"
echo 100 >"$STATE/containers/sub2api-postgres/max_connections"
ok init
contains "$OUT" "512 个数据库连接" "warning at init"
echo 1024 >"$STATE/containers/sub2api-postgres/max_connections"
ok deploy --image weishaw/sub2api:2
lacks "$OUT" "数据库连接" "no warning once the server allows enough connections"

# -----------------------------------------------------------------------------
scenario "destroy clears the state so init can run again"
# -----------------------------------------------------------------------------
add_legacy "127.0.0.1:3000"
ok init
ok deploy --image weishaw/sub2api:2
STDIN_TEXT="n
"
ok destroy
[ -d "$STATE/containers/sub2api-edge" ] || fail "destroy acted without confirmation"
STDIN_TEXT="y
"
ok destroy
STDIN_TEXT=""
[ ! -d "$STATE/containers/sub2api-edge" ] || fail "edge survived destroy"
[ ! -d "$STATE/containers/sub2api-blue" ] || fail "blue survived destroy"
[ ! -e "$RUNTIME/state.env" ] || fail "state file survived destroy"
refused deploy --image weishaw/sub2api:2
ok init
eq "$(state ACTIVE)" "blue" "init after destroy"
eq "$(cfile sub2api-edge binding)" "127.0.0.1:3000" "entry still copied from the stopped legacy container"
# The legacy container still holds the image from before the first deploy.
eq "$(cfile sub2api-blue config_image)" "weishaw/sub2api@sha256:d-two" "re-init resumes the version that served last, not the legacy container's"
eq "$(state LABEL_BLUE)" "weishaw/sub2api:2" "label carried over"
eq "$(cfile sub2api running)" "false" "a stopped legacy container is left alone"

printf 'bluegreen behavior test passed (%s scenarios)\n' "$SCENARIO"
