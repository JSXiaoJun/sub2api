#!/bin/sh
# =============================================================================
# Static checks for the blue-green deployment files
# =============================================================================
# These checks need neither docker nor a running deployment: they verify that
# the compose file, the edge Caddyfile and the helper script stay consistent
# with the single-container compose files they replace.
# =============================================================================
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

bg_dir=deploy/bluegreen
compose="$bg_dir/docker-compose.bg.yml"
caddyfile="$bg_dir/Caddyfile"
script="$bg_dir/bluegreen.sh"

fail() {
	printf 'bluegreen static test failed: %s\n' "$1" >&2
	exit 1
}

# -----------------------------------------------------------------------------
# 1. Shell syntax
# -----------------------------------------------------------------------------
/bin/bash -n "$script" || fail "$script has a syntax error"

if grep -q "$(printf '\r')" "$script"; then
	fail "$script has CRLF line endings (it would break inside Linux containers/hosts)"
fi

# The script is executed on Linux servers and parsed by macOS bash 3.2 in CI;
# reject bash-4-only constructs that would fail there.
if grep -nE 'mapfile|readarray|declare -A|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^' "$script" >/dev/null; then
	fail "$script uses bash-4-only syntax"
fi

# -----------------------------------------------------------------------------
# 2. Compose wiring
# -----------------------------------------------------------------------------
for needle in \
	'container_name: sub2api-${BG_SLOT:-blue}' \
	'name: ${BG_NETWORK:-sub2api-network}' \
	'external: true' \
	'TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY:?' \
	'SERVER_TRUSTED_PROXIES=' \
	'PRICING_DATA_DIR=' \
	'LOG_OUTPUT_FILE_PATH=' \
	'container_name: sub2api-edge' \
	'"${BG_EDGE_BIND_IP:-0.0.0.0}:${BG_EDGE_PORT:-8080}:8080"'
do
	grep -Fq -- "$needle" "$compose" || fail "$compose is missing: $needle"
done

# The slot must not be able to start postgres/redis: it joins the existing
# network instead of owning the database.
if grep -qE '^\s+depends_on:' "$compose"; then
	fail "$compose must not declare depends_on (postgres/redis live in another project)"
fi
if grep -qE '^\s+(postgres|redis):' "$compose"; then
	fail "$compose must not define postgres/redis services"
fi

# -----------------------------------------------------------------------------
# 3. Edge Caddyfile
# -----------------------------------------------------------------------------
for needle in \
	'auto_https off' \
	'import /etc/caddy/runtime/upstream.caddy' \
	'lb_policy first' \
	'lb_try_duration' \
	'health_uri /health' \
	'health_status 200' \
	'fail_duration' \
	'stream_close_delay' \
	'trusted_proxies private_ranges'
do
	grep -Fq -- "$needle" "$caddyfile" || fail "$caddyfile is missing: $needle"
done

# The edge must not reject a body the application accepts: its limit follows
# GATEWAY_MAX_BODY_SIZE, which the compose file has to hand to the edge
# container (the application service alone is not enough).
grep -Fq -- 'max_size {$GATEWAY_MAX_BODY_SIZE:268435456}' "$caddyfile" ||
	fail "$caddyfile must take the request body limit from GATEWAY_MAX_BODY_SIZE"
edge_env=$(awk '
	/^  edge:/ { in_edge = 1; next }
	in_edge && /^  [A-Za-z0-9_-]+:/ { in_edge = 0 }
	in_edge && /^[a-z]/ { in_edge = 0 }
	in_edge { print }
' "$compose")
printf '%s\n' "$edge_env" | grep -Fq -- '- GATEWAY_MAX_BODY_SIZE=${GATEWAY_MAX_BODY_SIZE:-268435456}' ||
	fail "$compose does not pass GATEWAY_MAX_BODY_SIZE to the edge service"

# text/event-stream must never be compressed, otherwise SSE turns into bursts.
if grep -qE 'header Content-Type +(text/\*|\*/\*)' "$caddyfile"; then
	fail "$caddyfile must not compress text/* (SSE would be buffered)"
fi

# -----------------------------------------------------------------------------
# 4. Data mount rendering (bind + named volume)
# -----------------------------------------------------------------------------
bind_output=$(/bin/bash "$script" render-mount bind /srv/sub2api/data)
printf '%s\n' "$bind_output" | grep -Fq '"/srv/sub2api/data:/app/data:Z"' ||
	fail "render-mount bind did not produce the expected bind mount"
if printf '%s\n' "$bind_output" | grep -Fq 'target: /app/data'; then
	fail "render-mount bind must not emit long syntax"
fi

volume_output=$(/bin/bash "$script" render-mount volume deploy_sub2api_data)
printf '%s\n' "$volume_output" | grep -Fq 'external: true' ||
	fail "render-mount volume did not mark the volume external"
printf '%s\n' "$volume_output" | grep -Fq 'name: "deploy_sub2api_data"' ||
	fail "render-mount volume did not pin the volume name"
printf '%s\n' "$volume_output" | grep -Fq 'source: bg_data' ||
	fail "render-mount volume did not reference the external volume key"

# -----------------------------------------------------------------------------
# 5. Environment drift guard
# -----------------------------------------------------------------------------
# docker-compose.bg.yml is a copy of the application service definition from the
# single-container compose files. If upstream adds a variable there and it is
# not mirrored here, a slot would silently boot with different configuration.
tsv=$(mktemp "${TMPDIR:-/tmp}/sub2api-bg-env.XXXXXX")
trap 'rm -f "$tsv"' EXIT HUP INT TERM

: >"$tsv"
for base in deploy/docker-compose.yml deploy/docker-compose.local.yml; do
	awk '
		/^  sub2api:/ { in_app = 1; next }
		in_app && /^  [A-Za-z0-9_-]+:/ { in_app = 0 }
		in_app && /^      - [A-Z0-9_]+=/ {
			match($0, /- [A-Z0-9_]+=/)
			print substr($0, RSTART + 2, RLENGTH - 3)
		}
	' "$base" >>"$tsv"
done

sort -u "$tsv" -o "$tsv"

# Guard the guard: if the awk parser ever stops matching, the drift check would
# silently pass on an empty list.
key_count=$(grep -c . "$tsv" || true)
if [ "${key_count:-0}" -lt 80 ]; then
	fail "environment drift guard extracted only ${key_count:-0} keys from the compose files"
fi

while IFS= read -r key; do
	[ -n "$key" ] || continue
	grep -qE "^[[:space:]]+-[[:space:]]+${key}=" "$compose" ||
		fail "$compose does not mirror $key from the single-container compose files"
done <"$tsv"

printf 'bluegreen static test passed\n'
