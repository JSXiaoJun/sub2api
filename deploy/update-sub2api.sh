#!/bin/bash
# =============================================================================
# sub2api 一键更新（蓝绿 / blue-green 部署）
#   备份 → 还原校验 → 切镜像 → 健康与版本验证
#
# 用法:
#   ./update-sub2api.sh                    备份 + 校验 + 更新到默认 tag
#   ./update-sub2api.sh backup             只备份 + 校验，不动线上
#   ./update-sub2api.sh update <tag>       备份 + 校验 + 更新到指定 tag
#   ./update-sub2api.sh rollback           切回上一个槽位（代码回滚，不回滚数据库）
#   ./update-sub2api.sh verify             只做健康 / 版本检查
#
# 环境变量:
#   DEFAULT_TAG=0.2.22-apikey-plugin   不带参数时使用的镜像 tag
#   STOP_OLD=600                       切流后多久停旧槽位（秒）
#   SKIP_RESTORE_CHECK=1               跳过还原校验（只做 dump 完整性检查，快）
#   BG_DIR=/opt/sub2api/deploy/bluegreen
# =============================================================================
set -euo pipefail

BG_DIR=${BG_DIR:-/opt/sub2api/deploy/bluegreen}
DEPLOY_DIR=$(dirname "$BG_DIR")
IMAGE_REPO=${IMAGE_REPO:-ghcr.io/jsxiaojun/sub2api}
DEFAULT_TAG=${DEFAULT_TAG:-0.2.22-apikey-plugin}
PG=${PG:-sub2api-postgres}
STOP_OLD=${STOP_OLD:-600}
SKIP_RESTORE_CHECK=${SKIP_RESTORE_CHECK:-0}

TS=$(date +%F-%H%M%S)
BACKUP_DIR=${BACKUP_DIR:-/root/backup/sub2api-$TS}
LOG="$BACKUP_DIR/update.log"
DUMP_NAME="sub2api-$TS.dump"
TMP_DB="restore_check_$(date +%s)"

# 校验用：用户|令牌|账号|分组|订阅|迁移记录
COUNT_SQL="select (select count(*) from users) || '|' || (select count(*) from api_keys) || '|' || (select count(*) from accounts) || '|' || (select count(*) from groups) || '|' || (select count(*) from user_subscriptions) || '|' || (select count(*) from schema_migrations);"

DB_USER=""
DB_NAME=""

say()  { printf '\n===== %s =====\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\n!!! %s\n' "$*" >&2; exit 1; }

# set -e 下意外失败会静默退出；这里补一行诊断（SIGPIPE 141 之类也能看懂）
trap 'rc=$?; printf "\n!!! 意外中止：退出码 %s（第 %s 行）\n" "$rc" "${LINENO:-?}" >&2' ERR

cleanup() {
  set +e
  if [ -n "$DB_USER" ]; then
    docker exec "$PG" psql -U "$DB_USER" -d postgres -q \
      -c "DROP DATABASE IF EXISTS \"$TMP_DB\" WITH (FORCE)" >/dev/null 2>&1
  fi
  docker exec "$PG" rm -f "/tmp/$DUMP_NAME" >/dev/null 2>&1
}
trap cleanup EXIT

check_counts() {
  local bk="$1" on="$2" i name x y tol d
  local -a A B
  IFS='|' read -r -a A <<<"$bk"
  IFS='|' read -r -a B <<<"$on"
  local names=(users api_keys accounts groups user_subscriptions schema_migrations)
  for i in "${!names[@]}"; do
    name=${names[$i]}
    x=${A[$i]:-}
    y=${B[$i]:-}
    [ -n "$x" ] && [ -n "$y" ] || die "校验字段缺失: $name"
    if [ "$name" = schema_migrations ]; then
      [ "$x" = "$y" ] || die "迁移记录数不一致（备份 $x / 线上 $y），备份不可信"
    else
      tol=$(( y / 100 )); [ "$tol" -lt 20 ] && tol=20
      if [ "$x" -gt "$y" ]; then d=$(( x - y )); else d=$(( y - x )); fi
      [ "$d" -le "$tol" ] || die "$name 行数差异过大（备份 $x / 线上 $y），备份不可信"
    fi
  done
  [ "${A[0]:-0}" -gt 0 ] || die "备份里 users 为 0，拒绝继续"
  info "行数校验通过 ✅"
}

verify_live() {
  local strict=${1:-1} active health ver expect st
  # status 只跑一次：管道直接喂给会提前退出的 awk 会让上游吃到 SIGPIPE（141），
  # 配合 pipefail + set -e 会静默中止。
  st=$("$BG_DIR/bluegreen.sh" status)
  printf '%s\n' "$st" | sed 's/^/  /'
  active=$(printf '%s\n' "$st" | awk -F': *' '/^active:/{print $2}')
  [ -n "$active" ] || die "读不到 active 槽位"
  health=$(curl -fsS --max-time 10 "http://127.0.0.1:8080/health" || true)
  [ "$health" = '{"status":"ok"}' ] || die "入口 /health 异常: ${health:-（无响应）}"
  info "入口 /health: $health"
  ver=$(docker exec "sub2api-$active" /app/sub2api -version 2>&1 \
        | grep -o 'Sub2API [0-9][0-9A-Za-z.\-]*' | head -1 || true)
  [ -n "$ver" ] || die "读不到槽位版本（sub2api-$active 是否在跑？）"
  info "槽位 $active 版本: $ver"
  info "槽位镜像: $(docker inspect -f '{{.Config.Image}}' "sub2api-$active" 2>/dev/null || echo 未知)"
  expect=${TAG%%-*}
  case "$expect" in
    0.*|1.*|2.*) ;;
    *) expect="" ;;
  esac
  if [ -n "$expect" ]; then
    case "$ver" in
      *"$expect"*) info "版本与 tag 一致 ✅" ;;
      *)
        if [ "$strict" = "1" ]; then
          die "版本不符: 期望含 $expect，实际 $ver"
        else
          info "⚠ 当前版本与默认 tag 不一致（期望含 $expect，实际 $ver），可能是回滚状态"
        fi
        ;;
    esac
  fi
  docker exec "$PG" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "select filename from schema_migrations order by applied_at desc limit 3" \
    | sed 's/^/  最近迁移: /'
}

MODE=${1:-update}
TAG=${2:-$DEFAULT_TAG}

case "$MODE" in
  backup|update|rollback|verify) ;;
  -h|--help|help) sed -n '2,18p' "$0"; exit 0 ;;
  *) die "未知参数: $MODE（可用: update <tag> | backup | rollback | verify）" ;;
esac

if [ "$MODE" = rollback ]; then
  exec "$BG_DIR/bluegreen.sh" rollback
fi

# ---------------------------------------------------------------------------
say "[1/6] 前置检查"
[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
command -v docker >/dev/null 2>&1 || die "找不到 docker 命令"
[ -x "$BG_DIR/bluegreen.sh" ] || die "找不到 $BG_DIR/bluegreen.sh"
[ -f "$BG_DIR/.runtime/state.env" ] || die "bluegreen 尚未初始化（先执行 $BG_DIR/bluegreen.sh init）"
[ "$(docker inspect -f '{{.State.Running}}' "$PG" 2>/dev/null || echo false)" = "true" ] \
  || die "PostgreSQL 容器 $PG 没在运行"
DB_USER=$(docker exec "$PG" sh -c 'printf %s "$POSTGRES_USER"')
DB_NAME=$(docker exec "$PG" sh -c 'printf %s "$POSTGRES_DB"')
[ -n "$DB_USER" ] && [ -n "$DB_NAME" ] || die "读不到 POSTGRES_USER / POSTGRES_DB"
AVAIL_KB=$(df -Pk /root | awk 'NR==2{print $4}')
[ "$AVAIL_KB" -gt 5242880 ] || die "根分区可用空间不足 5G（当前 $((AVAIL_KB/1024/1024))G）"
info "数据库: $DB_USER@$DB_NAME   容器: $PG   镜像: $IMAGE_REPO:$TAG"
"$BG_DIR/bluegreen.sh" status | sed 's/^/  /'

if [ "$MODE" = "verify" ]; then
  say "[verify] 只做健康与版本检查，不改动线上"
  verify_live 0
  exit 0
fi

# ---------------------------------------------------------------------------
say "[2/6] 备份 -> $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
info "dump 数据库（-Fc，压缩）..."
docker exec "$PG" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc -f "/tmp/$DUMP_NAME"
docker cp "$PG:/tmp/$DUMP_NAME" "$BACKUP_DIR/$DUMP_NAME"
cp -a "$DEPLOY_DIR/.env" "$BACKUP_DIR/.env" 2>/dev/null || true
cp -a "$DEPLOY_DIR/docker-compose.local.yml" "$BACKUP_DIR/" 2>/dev/null || true
info "打包 data 目录（config.yaml / 插件 / pricing）..."
tar czf "$BACKUP_DIR/data.tar.gz" -C "$DEPLOY_DIR" data
"$BG_DIR/bluegreen.sh" status > "$BACKUP_DIR/status-before.txt" 2>&1 || true
docker ps --format '{{.Names}}\t{{.Image}}' > "$BACKUP_DIR/containers-before.txt" 2>&1 || true
ls -lh "$BACKUP_DIR" | sed 's/^/  /'
ln -sfn "$BACKUP_DIR" /root/backup/latest

# ---------------------------------------------------------------------------
say "[3/6] 校验备份"
TOC=$(docker exec "$PG" pg_restore -l "/tmp/$DUMP_NAME" | wc -l)
[ "$TOC" -gt 50 ] || die "备份 TOC 只有 $TOC 行，dump 可能不完整"
info "TOC 条目: $TOC（文件结构完整）"

if [ "$SKIP_RESTORE_CHECK" = "1" ]; then
  info "已跳过还原校验（SKIP_RESTORE_CHECK=1）"
else
  info "还原到临时库 $TMP_DB 校验（大库需要几分钟）..."
  docker exec "$PG" psql -U "$DB_USER" -d postgres -q -c "DROP DATABASE IF EXISTS \"$TMP_DB\" WITH (FORCE)"
  docker exec "$PG" psql -U "$DB_USER" -d postgres -q -c "CREATE DATABASE \"$TMP_DB\""
  set +e
  docker exec "$PG" pg_restore -U "$DB_USER" -d "$TMP_DB" --no-owner --no-privileges -j 4 \
    "/tmp/$DUMP_NAME" >"$BACKUP_DIR/restore-check.log" 2>&1
  RC=$?
  set -e
  [ "$RC" -eq 0 ] || info "（pg_restore 返回 $RC，有警告，详见 restore-check.log；以行数校验为准）"
  BK=$(docker exec "$PG" psql -U "$DB_USER" -d "$TMP_DB" -tAc "$COUNT_SQL")
  ON=$(docker exec "$PG" psql -U "$DB_USER" -d "$DB_NAME" -tAc "$COUNT_SQL")
  info "                用户|令牌|账号|分组|订阅|迁移"
  info "备份库:  $BK"
  info "线上库:  $ON"
  check_counts "$BK" "$ON"
  docker exec "$PG" psql -U "$DB_USER" -d postgres -q -c "DROP DATABASE IF EXISTS \"$TMP_DB\" WITH (FORCE)"
fi
info "备份位置: $BACKUP_DIR"

if [ "$MODE" = "backup" ]; then
  say "只备份模式，未更新线上"
  exit 0
fi

# ---------------------------------------------------------------------------
say "[4/6] 部署新版本 $IMAGE_REPO:$TAG"
cd "$BG_DIR"
set +e
"$BG_DIR/bluegreen.sh" deploy --image "$IMAGE_REPO:$TAG" --stop-old="$STOP_OLD" 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -ne 0 ]; then
  info ""
  info "部署失败（退出码 $RC）。旧槽位仍在服务，线上未受影响。"
  info "常见原因：镜像拉取被拒 -> docker login ghcr.io -u <用户名>；或新版本健康检查没通过。"
  info "完整日志: $LOG"
  exit 1
fi

# ---------------------------------------------------------------------------
say "[5/6] 更新后验证"
verify_live 1

# ---------------------------------------------------------------------------
say "[6/6] 完成"
{
  echo ""
  echo "时间: $(date '+%F %T')"
  echo "镜像: $IMAGE_REPO:$TAG"
  echo "备份: $BACKUP_DIR"
  echo "回滚: $BG_DIR/bluegreen.sh rollback"
} >> "$LOG"
info "镜像: $IMAGE_REPO:$TAG"
info "备份: $BACKUP_DIR（latest 软链接已更新）"
info "回滚: $BG_DIR/bluegreen.sh rollback （只回代码，不回滚数据库迁移）"
info "旧槽位将在 ${STOP_OLD}s 后自动停止；想立刻停: $BG_DIR/bluegreen.sh stop <slot>"
info "下一步：到 /admin/plugins 上传对应的 .s2plugin 包并启用（新槽位插件目录是空的）"
