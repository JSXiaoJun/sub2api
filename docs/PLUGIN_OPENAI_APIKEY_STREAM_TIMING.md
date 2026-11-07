# OpenAI API Key 出站插件（首个事件计时）：站点适配与维护

本文记录把 AM1 的 `inventory.openai.stream-timing`（0.1.4-am1.1）API Key 适配包接入本仓库
Sub2API 0.2.20 的改动、部署方式、验证结果、已知限制和回退步骤。

## 1. 适用对象

| 项目 | 值 |
| --- | --- |
| 宿主基线 | Sub2API `0.2.20`（`backend/cmd/server/VERSION`；由 0.2.19 + 上游 0.2.20 修复合并而来） |
| 宿主改造分支 | `feat/plugin-apikey-0.2.20`（旧分支 `feat/plugin-openai-apikey-outbound` 为 0.2.19 基线） |
| 插件 ID / 版本 | `inventory.openai.stream-timing` / `0.1.4-am1.1`（派生 API Key-only 包） |
| 能力 | `openai.apikey.outbound_transport.v1`，平台 `openai`，账号类型 `apikey` |
| 账号范围 | **仅 OpenAI → API Key 上游账号**；OAuth 账号不使用此绑定 |
| 接口范围 | 原生 `POST /v1/responses` 且真实请求体 `stream:true` |
| 管理入口 | 后台 `/admin/plugins`（API：`/api/v1/admin/plugins`） |
| 默认状态 | 安装后 `disabled`，配置 `{"mode":"off"}` |

不接管的路径：非流式 Responses、`/v1/chat/completions`、`/v1/embeddings`、
`/v1/images/*`、`/v1/responses/compact`、`/v1/responses/input_tokens`、原生上游 WebSocket。
Sub2API 会把部分接口转换为 `/responses` 流式请求（Chat Completions 桥接、Anthropic Messages
桥接、图像生成内部调用、WebSocket→HTTP 桥接）。本实现只给**原生 `/v1/responses` 入口**生成
的出站请求打标，转换型桥接保持原路径，避免改变这些接口的首字、重试和错误语义。

## 2. 宿主改动（最小增量）

改动都在 `backend/internal/service` 与插件管理页面：

1. `plugin_manifest.go`：新增 `openai.apikey.outbound_transport.v1` 常量与
   `validOpenAIOutboundCapability`。每个能力只授予一个账号类型；API Key 能力**不**授予
   账号目录（不暴露账号凭据或账号枚举）。
2. `plugin_manager.go`：路由快照拆成 OAuth 和 API Key 两个灰度比例；`RoundTripOpenAIOutbound`
   按账号类型分发，`RoundTripOpenAIOAuth` 保留原 OAuth 语义；`bindingRollout` 缺省值由
   `100` 改为 `0`（缺少绑定不得当作全量路由）；数据库不可读时沿用最后一次显式 API Key 范围。
3. `openai_plugin_transport.go`：私有 context 标记记录「真实请求体是否 `stream:true`」，
   不读取/缓冲/消费请求体；第 4 点的两个真实出站请求构造器打标；API Key 出站前补做
   解析 IP 校验（与原生 API Key 路径一致）。
4. `openai_gateway_forward.go` / `openai_gateway_passthrough.go`：在请求构造完成处打标。
5. `account_test_service.go`：OpenAI Responses 账号测试与真实转发走同一插件路径。
6. 前端 `PluginsView.vue` + 中英文案：灰度显示不再只按 OAuth 绑定取值，文案改为
   OAuth/API Key 两类绑定。

与 AM1 参考补丁 `host-reference/host-apikey-AM1-reference.patch` 的差异只有一处：
参考补丁在请求构造器无条件打标，因而 Chat Completions→Responses 桥接也会进入插件；本实现
增加「下游入口必须是原生 `/v1/responses`」的门槛（`TestAPIKeyPluginActualRequestBuildersMarkOnlyNativeResponses`）。
路由判断本身仍只看上游 `POST .../responses` + 私有标记，不看客户端可伪造的请求头。

## 3. 安装与启用

### 3.1 先决条件

- 宿主必须是包含本分支改动的构建（未改动的 0.2.20 只支持 OAuth 能力，上传候选包会显示
  「不支持的出站能力」）。这一步需要重新构建并重启主应用。
- 以 Docker 部署为例：数据卷 `sub2api_data` 挂载到 `/app/data`，配置为
  `/app/data/config.yaml`，插件目录默认 `/app/data/plugins`。
- 保留当前镜像/二进制、`config.yaml`、数据库备份快照。

### 3.2 信任发布者

把下面条目**合并**进现有 `config.yaml` 的 `plugins` 段（不要整段覆盖，保留已有发布者）：

```yaml
plugins:
  allow_unsigned: false
  trusted_publishers:
    sub2api-apikey-stream-timing-20261104: "8OXAxfSk8ehTCW1MKx7l+tivxna6CL3Q4+Sdv565tMA="
```

新增信任公钥和新增宿主代码都需要重启主应用才能生效。

### 3.3 上传

1. 管理员登录 `/admin/plugins`，上传
   `stream-timing-0.1.4-am1.1-apikey-0.2.20.s2plugin`（不是外层 ZIP）。
2. 确认：签名「已验证」、兼容「当前版本已测试」、状态「已停用」、只有一条
   API Key 绑定且为关闭。
3. 保存配置 `{"mode":"off"}`，执行「测试」（本地配置校验，不访问上游）。

### 3.4 启用（需要管理员明确决定）

启用接口会打开该插件**已声明的全部绑定**。派生包只声明 API Key，因此启用只会打开
API Key 绑定；仍然要在启用后读回确认 OAuth 绑定不存在、API Key 绑定已开启。

- 灰度按账号 ID 哈希分桶，`rollout_percent=30` 表示稳定命中的是一部分账号，不是「每 100 个
  请求随机放行 30 个」。
- 建议顺序：`mode=off` 全量绑定 → 低比例账号 `mode=hint` → 观察账单与错误率 → 再调整。

## 4. 配置

| 字段 | 含义 |
| --- | --- |
| `mode` | `off` 不改写流；`hint` 等待后补一个空提示；`delay` 增加延迟 |
| `hint_after_ms` | 固定等待阈值（`mode=hint`） |
| `hint_wait_mode` / `hint_min_ms` / `hint_max_ms` | 随机等待区间 |
| `retry_max_attempts` | 插件内部额外重试次数（默认 2，0 关闭），同账号、输出前、受时间/体积/并发约束 |
| `response_header_timeout_seconds` 等 | 出站 HTTP 客户端参数 |

插件配置由插件自身校验并规范化，宿主保存密文。

## 5. 验证（隔离环境，未接真实流量）

命令与结果见交付目录 `verification/验证报告.md`。摘要：

- 宿主 `go build ./...`、`go vet`、`go test ./internal/service` 全量通过。
- 新增 12 个测试：路由边界、私有标记不可伪造、公网 IP 限制、真实进程流、`mode=off`
  逐字节透传、非流式、错误、取消、重试、数据库不可读时范围不变。
- 真实插件进程 + 本地模拟上游：提示平均在 ~100ms 到达，真实首 token 在 ~400ms；提示为
  `event: sub2api.timing` 空 delta，真实文本和完成事件 `usage` 原样保留。
- 取消在 3 秒内传递到上游。
- 已知缺陷已固化断言：提示发出后上游 503 JSON 带 `usage` 时，交付流里**看不到**该 usage；
  未提示的 503 则逐字节保留。

## 6. 已知限制（必须按此解释）

1. 空提示 ≠ 模型文字提前。它提前提交了 HTTP 200/SSE 首事件，只影响采用 semantic 首事件的
   计时；真实文字、推理和工具结果仍需等上游。部分客户端（含 Chat 桥接）会忽略该事件。
2. 不只是显示差异：提示后上游失败会变成流内失败，依赖「首字」的调度/评分可能受影响。
3. 插件自带有限重试（默认最多额外 2 次、同账号、输出前）。实测重试会在成功后继续只发一次
   提示，但重试本身会增加上游请求次数。
4. 已复现缺陷：提示后晚到 HTTP 错误（例如 503 JSON + `usage`）会丢失该 usage。成功流的
   usage 与账单一致，不能据此推断所有失败路径计费正确。
5. `mode=off` 仍然走插件传输路径（插件进程在链路上），只是不改写流；要让新请求退出插件
   路径必须「停用插件」。
6. 停用会排空最多约 10 秒，超时长请求可能被断开；已进入的请求继续使用进入时的配置。
7. 插件只支持 Linux amd64 / Windows amd64 二进制；其他架构需要自行重编译。

## 7. 回退

按影响从小到大：

1. **停用插件**：`/admin/plugins` → 停用；或
   `POST /api/v1/admin/plugins/{id}/disable`。读回所有绑定 `enabled=false`，`GET /status`
   显示未运行。新请求立即回到原生路径。
2. **配置回退**：`PUT /api/v1/admin/plugins/{id}/config`，正文 `{"mode":"off"}`。
   注意这只停止流改写，不退出插件传输路径。
3. **卸载插件**：停用后 `DELETE /api/v1/admin/plugins/{id}`，再移除 `config.yaml` 中的
   信任公钥条目（可选，保留不影响停用状态）。
4. **回退宿主**：换回改造前的镜像/二进制与 `config.yaml`，重启主应用。**不要用旧数据库
   备份覆盖新账务数据。** 回退后复查：正常转发、余额查询、新使用记录、插件状态。

## 8. 维护：重新出包

`source/` 是原插件源码（未改动）。派生包只改清单、重新签名，运行二进制沿用原签名包内文件
（SHA256 与原件一致），因此不需要重编译插件：

```sh
# 1) 从原包解出 runtimes/* 到 build/ 与 ui/，复制 manifest.source.json
# 2) 清单只保留 API Key 能力，并声明真实验证过的宿主版本
# 3) 用站点自己的私钥签名（私钥放在包目录外）
go run ./cmd/packager -root <pkgroot> -key <keys>/publisher.private \
  -key-id sub2api-apikey-stream-timing-20261104 -out <pkgroot>/dist/<name>.s2plugin
# 4) 只读校验
go run tools/verify-package.go <pkg>.s2plugin <pub>.public
```

- 版本号保持 `0.1.4-am1.1`（插件进程 `GetInfo` 上报该版本，清单必须一致）；派生包用
  SHA256 区分。
- 若将来升级宿主版本：先改 `requires.sub2api` 与 `tested_sub2api_versions`，重新签名，
  在隔离环境重跑第 5 节全部用例，再部署。
- 不要为通过兼容检查而伪造 `VERSION`、关闭签名校验或跳过登录/二次验证。

## 9. 相关测试

```sh
# 宿主（含真实插件进程集成测试）
SUB2API_TEST_APIKEY_PLUGIN_PACKAGE=<pkg> \
SUB2API_TEST_APIKEY_PLUGIN_KEY_ID=sub2api-apikey-stream-timing-20261104 \
SUB2API_TEST_APIKEY_PLUGIN_PUBLIC_KEY=<base64> \
go test ./internal/service -run TestAPIKeyPlugin -count=1

# 与宿主无关的插件自身回归（原始 OAuth 夹具）
cd source && go test ./internal/timing -count=1
# API Key 夹具（临时 overlay，不改源码）
python tools/test-apikey.py
```
