# Sub2API 蓝绿部署(单机 Docker)

把"停容器 → 换镜像 → 起容器"换成"新版本先起在空闲槽位 → 健康检查 → 切流 → 再停旧槽位"。
数据库和 Redis 沿用现有部署,本目录不会启动、停止或迁移它们。

```
                 :8080(原端口)
                     │
                 ┌───▼────┐        sub2api-edge (Caddy)
                 │  edge  │        lb_policy first + 健康检查
                 └───┬────┘
          ┌──────────┴──────────┐
     ┌────▼─────┐          ┌────▼─────┐
     │  blue    │          │  green   │   同一镜像仓库,不同 tag
     │ :8080内部│          │ :8080内部│   各自 127.0.0.1:18080/18081 仅调试
     └────┬─────┘          └────┬─────┘
          └──────────┬──────────┘
              ┌──────▼──────┐   ┌─────────┐
              │  PostgreSQL │   │  Redis  │   现有 compose 里的服务
              └─────────────┘   └─────────┘
```

同一时刻只有一个槽位接流量;另一个是"下一次部署的位置",也是秒级回滚的目标。

## 前置条件

- 现有部署是仓库的 Docker compose(单机),`.env` 里有 `TOTP_ENCRYPTION_KEY`,
  且是 64 位十六进制字符(`openssl rand -hex 32` 的输出)。
  **两个槽位必须用同一把密钥**,否则 2FA 和凭证密文互相解不开 —— 脚本会在 preflight 阶段直接拒绝
  为空、长度不对或含非十六进制字符的密钥(应用本身也会拒绝启动)。
- 宿主机能跑 `docker compose`(v2 或 v1 均可),且 edge 能占用原端口(默认 8080)。
- 磁盘能同时容纳两个槽位的容器(镜像层共享,占用很小)和少量运行期目录。
- 数据库连接数够两个槽位同时使用:`DATABASE_MAX_OPEN_CONNS × 2` 不超过 PostgreSQL 的
  `max_connections`(留 3 个给超级用户)。脚本在 `init` / `deploy` 时会向数据库容器查询实际值,
  不够时给出警告。

## 首次接入

把本目录放到现有 `.env` 旁边(例如 `/opt/sub2api/bluegreen/`),然后:

```bash
chmod +x bluegreen.sh
./bluegreen.sh init
```

`init` 会:

1. 检测现有 `sub2api` 容器 → 得到网络名、数据卷/目录、对外监听地址和端口;
2. 检查 `TOTP_ENCRYPTION_KEY`;
3. 用**当前正在跑的镜像**在 blue 槽位启动一份(按 digest/镜像 ID 固定,不会因为 `:latest` 被重新解析而变成新版本);
4. 等 blue 的 `/health` 就绪(首次会跑数据库迁移,可能几分钟);
5. 停掉旧容器(并把它的 `restart` 策略改为 `no`),启动 edge 接管原来的地址和端口;
6. 校验入口 `/health`,通过后才写入状态文件。

edge 监听的地址与旧容器**完全一致**:旧容器只发布在 `127.0.0.1` 时(前面有 TLS 代理),
edge 也只监听 `127.0.0.1`,不会把明文端口暴露到所有网卡。

**这一步会有约 2~5 秒的端口空窗**:旧容器释放端口 → edge 绑定端口。
这是整个方案里唯一一次不可避免的中断。之后的升级都是零中断。

第 5、6 步失败时脚本会自动撤销:删除 edge 和 blue,恢复旧容器及其重启策略,不留状态文件。
排除问题后直接重新运行 `./bluegreen.sh init` 即可。

`init` **不升级版本**:它把当前镜像原封不动搬到 blue 槽位,只是把入口从"单容器"换成"edge + 槽位"。
所以不要想着跳过 `init` 直接 `deploy` —— 未初始化时脚本会直接拒绝。

> 之后不要再对原来的 compose 执行 `docker compose up -d` —— 它会把旧的 `sub2api` 容器拉起来抢 8080。
> 需要 pgsql/redis 时只启动它们即可:`docker compose up -d postgres redis`。

## 日常升级

```bash
./bluegreen.sh deploy --image weishaw/sub2api:0.2.21
```

流程:拉镜像 → 把标签固定为 digest → 部署到空闲槽位 → 等 `/health` → 改写 `edge` 的上游顺序并热加载 → 校验入口。
任何一步失败都会保持/恢复原槽位继续服务;没能就绪的新槽位会被停止(不会反复重启),日志仍可用 `logs` 查看。

**镜像按 digest 固定。** 状态文件里记录的是 `--image` 标签当时指向的 digest(本地构建、从未推送的镜像则记录镜像 ID),
所以之后 `:latest` 这类标签再移动,`rollback` 和 `start` 拉起的仍是当时那个版本。`status` 同时显示标签和固定值。

**同一时刻只允许一个命令。** `init` / `deploy` / `rollback` / `switch` / `start` / `stop` 之间互斥,
第二个会直接报错退出。`--stop-old` 的等待期间不占锁,可以随时 `rollback`。

切流成功后,**旧槽位默认继续运行但不接新流量**,因为:

- 网关有持续十几分钟的 SSE 流式响应,进程收到 SIGTERM 后只有 5 秒排空时间;
- 立刻停旧槽位会掐断在途请求。

确认没有在途流式请求后手动停:`./bluegreen.sh stop blue`。
或者让脚本延迟停:`./bluegreen.sh deploy --image ... --stop-old=600`(切流后等 600 秒)。
等待结束时脚本会重新读取状态:如果期间执行过 `rollback` / `switch`,旧槽位已重新承接流量,就不再停它。

## 回滚

```bash
./bluegreen.sh rollback
```

- 旧槽位还在运行且健康 → 直接改上游顺序,秒级完成;
- 旧槽位还在运行但不健康 → 拒绝切流,流量留在当前槽位(入口校验会被 Caddy 的故障转移掩盖,所以脚本直接问槽位本身);
- 旧槽位已被停止 → 用状态文件里固定的镜像重新拉起,健康检查通过后再切。

`stop` 同理:当前 active 槽位不健康时,流量实际由另一个槽位承接,脚本拒绝停它。

⚠️ 回滚只回滚**代码**,不回滚数据库。如果新版本已经执行了不兼容的迁移(例如删列/改列),
旧代码可能跑不起来 —— 见下面的"迁移纪律"。

## 命令参考

| 命令 | 作用 |
| --- | --- |
| `init [--force]` | 首次接入;`--force` 把状态文件与运行中的容器对齐并应用 `BG_*` 覆盖(不重建容器) |
| `deploy [--image TAG] [--stop-old[=SECS]] [--keep-old]` | 部署新版本并切流 |
| `rollback` | 切回上一个槽位 |
| `switch <blue\|green>` | 手动切到某个已在运行且健康的槽位 |
| `status` | 槽位状态、镜像(标签与固定值)、健康、当前上游 |
| `start <slot>` / `stop <slot>` | 启动/停止槽位(不切流;拒绝停 active 或正在承接流量的槽位) |
| `recreate-edge` | 用当前状态重建 edge(入口中断几秒) |
| `logs <blue\|green\|edge> [-f]` | 看日志 |
| `destroy` | 删除 edge 与两个槽位容器并清除状态(不碰数据库);之后重新 `init` 会沿用 destroy 前 active 槽位的版本 |

可选环境变量见 [env.example](env.example)。它们分两类:

- `BG_ENV_FILE` / `BG_IMAGE_DEFAULT` / `BG_HEALTH_TIMEOUT` / `BG_EDGE_IMAGE`:每次命令都读取;
- `BG_NETWORK` / `BG_TRUSTED_PROXIES` / `BG_EDGE_PORT` / `BG_EDGE_BIND_IP` / `BG_BLUE_PORT` / `BG_GREEN_PORT` / `BG_BIND_IP`:
  只在 `init` 和 `init --force` 时读取并写入状态文件。在其他命令上设置它们只会得到一条警告,
  因为容器已经按保存的值创建了。

修改第二类的步骤:

```bash
BG_EDGE_PORT=8081 ./bluegreen.sh init --force
```

```bash
./bluegreen.sh recreate-edge
```

入口端口和监听地址在 `recreate-edge` 后生效;网络、调试端口、可信代理在下一次 `deploy` 时对新槽位生效。

## 设计约束(为什么这么做)

**数据目录共享、运行期文件隔离。** 两个槽位挂同一个 `/app/data`,这样 `config.yaml` 和既有数据直接复用;
但应用会重写 `pricing/`、`plugins/`、`logs/`,两边同时写会互相踩,所以按槽位注入
`PRICING_DATA_DIR` / `PLUGINS_DATA_DIR` / `LOG_OUTPUT_FILE_PATH` 到 `/app/data/runtime/<slot>/`。

**迁移在启动时自动执行。** 新槽位启动会跑 `migrations/`,用 PostgreSQL advisory lock 串行化,
不会和老槽位抢;但**旧槽位会继续运行在新 schema 上**。因此:

- 加列/建表/加索引这类 expand 迁移可以放心;
- 删列/改语义的 contract 迁移要拆到下个版本(先双写兼容,再删),否则这次切换期间旧代码会读不到列;
- 大型 `ALTER TABLE` 会短暂锁表,旧槽位可能出现几秒延迟,建议在低峰期部署。

**并发占位在两个槽位间共享。** 账号/用户的并发槽位存在 Redis 里。应用启动时会回收"已死进程"留下的占位;
为了不把另一个槽位的在途请求当成残留,每个进程会在 Redis 里登记心跳(`concurrency:process_registry`),
启动清理只回收没有心跳的进程。**这要求两个槽位运行的版本都带有这个登记机制**:
从不带它的旧版本升级的那一次,旧槽位没有登记,新槽位启动时仍会清掉它的占位
(在途请求不受影响,但并发上限在这些请求结束前可能被突破)。之后的升级不再有这个问题。

**入口只有一层薄代理。** edge 只做转发、负载均衡和健康检查,不终止 TLS:
它接管你原来的地址和端口,所以前面如果已有 HTTPS 终结器(Caddy/Nginx/CDN),配置不用改。
请求体上限跟随 `.env` 里的 `GATEWAY_MAX_BODY_SIZE`(默认 256MB),修改后执行 `recreate-edge` 生效。

**客户端 IP。** 应用现在从 edge 进来,必须信任 docker 网段才能解析 `X-Forwarded-For`。
脚本会把网段写入 `SERVER_TRUSTED_PROXIES`;edge 只信任 RFC1918 来源的转发头,公网请求的
`X-Forwarded-*` 一律重写,防伪造。

**WebSocket 与 SSE。** `caddy reload` 默认会关闭 WebSocket 隧道,配置里用 `stream_close_delay 5m`
让老连接自然过渡;SSE 响应在 reload 时不会被切断,可以正常排空。

## 排障

```bash
./bluegreen.sh status
./bluegreen.sh logs edge
./bluegreen.sh logs green
docker inspect sub2api-green --format '{{.State.Health.Status}}'
```

- **卡在"等待就绪"**:首次启动在跑迁移,看 `logs <slot>`;超时后脚本会打印最近 100 行并放弃,
  当前流量不受影响。
- **入口 502**:两个上游都被判定不健康。检查槽位健康与 edge 的 `upstream` 文件:
  `cat .runtime/upstream.caddy`。
- **升级后客户端 IP 全变成容器内网 IP**:在 `.env` 里显式设 `SERVER_TRUSTED_PROXIES=<edge 所在网段>`,
  下次 `deploy` 生效;要立刻生效只能重建当前槽位(会有短暂中断)。
- **状态文件与实际不符**(网络/挂载/端口):`./bluegreen.sh init --force` 以正在运行的 active 槽位和 edge 为准
  重新写入状态文件,不会动容器;需要改成别的值时在命令前加 `BG_*` 覆盖。
- **回滚后登录态异常**:确认两个槽位使用同一个 `TOTP_ENCRYPTION_KEY`;`JWT_SECRET` 会落库共享。
- **端口被占**:`init` 会自己停掉旧容器再启动 edge;如果是别的进程占用,`init` 会撤销并恢复旧容器,
  换端口用 `BG_EDGE_PORT=<端口> ./bluegreen.sh init`。
- **"另一个 bluegreen.sh 正在运行"**:等它结束。确认没有其他实例而锁残留时(进程被 `kill -9`),
  脚本会自动清理;仍然报错再手动删除 `.runtime/lock`。
- **edge 容器被误删**:`./bluegreen.sh recreate-edge`。
- **`too many clients`**:两个槽位的连接池之和超过了数据库上限,调大 `POSTGRES_MAX_CONNECTIONS`
  或调小 `DATABASE_MAX_OPEN_CONNS`,并及时停掉不再需要的旧槽位。

## 限制

- 只适用于**单机 Docker**:数据目录是宿主路径或本机卷,不能跨主机。
- edge 是单点。要更高可用,需要把 edge 换成外部负载均衡(本方案的上游文件可直接被 Nginx 等引用)。
- 不做流量比例灰度(如 5% 新版本)。需要灰度请改用 `lb_policy weighted_round_robin` 并自行调整权重。
- 不自动回滚"业务指标变差":健康检查通过即认为可切,业务验证仍需人工观察。
