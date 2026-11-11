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

- 现有部署是仓库的 Docker compose(单机),`.env` 里有 `TOTP_ENCRYPTION_KEY`。
  **两个槽位必须用同一把密钥**,否则 2FA 和凭证密文互相解不开 —— 脚本会在 preflight 阶段直接拒绝。
- 宿主机能跑 `docker compose`(v2 或 v1 均可),且 edge 能占用原端口(默认 8080)。
- 磁盘能同时容纳两个槽位的容器(镜像层共享,占用很小)和少量运行期目录。

## 首次接入

把本目录放到现有 `.env` 旁边(例如 `/opt/sub2api/bluegreen/`),然后:

```bash
chmod +x bluegreen.sh
./bluegreen.sh init
```

`init` 会:

1. 检测现有 `sub2api` 容器 → 得到网络名、数据卷/目录、对外端口;
2. 检查 `TOTP_ENCRYPTION_KEY`;
3. 用**当前正在跑的镜像**在 blue 槽位启动一份(按 digest/镜像 ID 固定,不会因为 `:latest` 被重新解析而变成新版本);
4. 等 blue 的 `/health` 就绪(首次会跑数据库迁移,可能几分钟);
5. 停掉旧容器(并把它的 `restart` 策略改为 `no`),启动 edge 接管 8080;
6. 校验入口 `/health`。

**这一步会有约 2~5 秒的端口空窗**:旧容器释放 8080 → edge 绑定 8080。
这是整个方案里唯一一次不可避免的中断。之后的升级都是零中断。

`init` **不升级版本**:它把当前镜像原封不动搬到 blue 槽位,只是把入口从"单容器"换成"edge + 槽位"。
所以不要想着跳过 `init` 直接 `deploy` —— 未初始化时脚本会直接拒绝。

> 之后不要再对原来的 compose 执行 `docker compose up -d` —— 它会把旧的 `sub2api` 容器拉起来抢 8080。
> 需要 pgsql/redis 时只启动它们即可:`docker compose up -d postgres redis`。

## 日常升级

```bash
./bluegreen.sh deploy --image weishaw/sub2api:0.2.21
```

流程:拉镜像 → 部署到空闲槽位 → 等 `/health` → 改写 `edge` 的上游顺序并热加载 → 校验入口。
任何一步失败都会保持/恢复原槽位继续服务。

切流成功后,**旧槽位默认继续运行但不接新流量**,因为:

- 网关有持续十几分钟的 SSE 流式响应,进程收到 SIGTERM 后只有 5 秒排空时间;
- 立刻停旧槽位会掐断在途请求。

确认没有在途流式请求后手动停:`./bluegreen.sh stop blue`。
或者让脚本延迟停:`./bluegreen.sh deploy --image ... --stop-old=600`(切流后等 600 秒)。

## 回滚

```bash
./bluegreen.sh rollback
```

- 旧槽位还在运行 → 直接改上游顺序,秒级完成;
- 旧槽位已被停止 → 用状态文件里记录的镜像重新拉起,健康检查通过后再切。

⚠️ 回滚只回滚**代码**,不回滚数据库。如果新版本已经执行了不兼容的迁移(例如删列/改列),
旧代码可能跑不起来 —— 见下面的"迁移纪律"。

## 命令参考

| 命令 | 作用 |
| --- | --- |
| `init [--force]` | 首次接入/重新检测环境 |
| `deploy [--image TAG] [--stop-old[=SECS]] [--keep-old]` | 部署新版本并切流 |
| `rollback` | 切回上一个槽位 |
| `switch <blue\|green>` | 手动切到某个已在运行且健康的槽位 |
| `status` | 槽位状态、镜像、健康、当前上游 |
| `start <slot>` / `stop <slot>` | 启动/停止槽位(不切流;拒绝停 active) |
| `logs <blue\|green\|edge> [-f]` | 看日志 |
| `destroy` | 删除 edge 与两个槽位容器(不碰数据库) |

可选环境变量见 [env.example](env.example)。

## 设计约束(为什么这么做)

**数据目录共享、运行期文件隔离。** 两个槽位挂同一个 `/app/data`,这样 `config.yaml` 和既有数据直接复用;
但应用会重写 `pricing/`、`plugins/`、`logs/`,两边同时写会互相踩,所以按槽位注入
`PRICING_DATA_DIR` / `PLUGINS_DATA_DIR` / `LOG_OUTPUT_FILE_PATH` 到 `/app/data/runtime/<slot>/`。

**迁移在启动时自动执行。** 新槽位启动会跑 `migrations/`,用 PostgreSQL advisory lock 串行化,
不会和老槽位抢;但**旧槽位会继续运行在新 schema 上**。因此:

- 加列/建表/加索引这类 expand 迁移可以放心;
- 删列/改语义的 contract 迁移要拆到下个版本(先双写兼容,再删),否则这次切换期间旧代码会读不到列;
- 大型 `ALTER TABLE` 会短暂锁表,旧槽位可能出现几秒延迟,建议在低峰期部署。

**入口只有一层薄代理。** edge 只做转发、负载均衡和健康检查,不终止 TLS:
它接管你原来的端口,所以前面如果已有 HTTPS 终结器(Caddy/Nginx/CDN),配置不用改。

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
  环境探测错误(网络/挂载/端口)用 `./bluegreen.sh init --force` 只刷新检测结果,不会动容器。
- **回滚后登录态异常**:确认两个槽位使用同一个 `TOTP_ENCRYPTION_KEY`;`JWT_SECRET` 会落库共享。
- **端口被占**:`init` 之前先确认旧容器已停;edge 端口冲突时用 `BG_EDGE_PORT` 覆盖。

## 限制

- 只适用于**单机 Docker**:数据目录是宿主路径或本机卷,不能跨主机。
- edge 是单点。要更高可用,需要把 edge 换成外部负载均衡(本方案的上游文件可直接被 Nginx 等引用)。
- 不做流量比例灰度(如 5% 新版本)。需要灰度请改用 `lb_policy weighted_round_robin` 并自行调整权重。
- 不自动回滚"业务指标变差":健康检查通过即认为可切,业务验证仍需人工观察。
