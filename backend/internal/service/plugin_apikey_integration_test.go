package service

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"github.com/tidwall/gjson"
)

// 这组测试会真正启动候选 .s2plugin 进程，并通过真实 gRPC 传输把请求转发到本地
// 模拟上游。它不访问真实模型、真实账号或生产数据库。用环境变量提供候选包：
//
//	SUB2API_TEST_APIKEY_PLUGIN_PACKAGE=<派生包路径>
//	SUB2API_TEST_APIKEY_PLUGIN_KEY_ID=<发布者 key_id>
//	SUB2API_TEST_APIKEY_PLUGIN_PUBLIC_KEY=<ed25519 公钥 base64>
func apiKeyPluginTestEnv(t *testing.T) (string, string, string) {
	t.Helper()
	pkg := os.Getenv("SUB2API_TEST_APIKEY_PLUGIN_PACKAGE")
	keyID := os.Getenv("SUB2API_TEST_APIKEY_PLUGIN_KEY_ID")
	pub := os.Getenv("SUB2API_TEST_APIKEY_PLUGIN_PUBLIC_KEY")
	if pkg == "" || keyID == "" || pub == "" {
		t.Skip("未提供 API Key 插件候选包与公钥，跳过插件进程集成测试")
	}
	return pkg, keyID, pub
}

func installAPIKeyPlugin(t *testing.T, pkg, keyID, pub string) *PluginInstallation {
	t.Helper()
	cfg := testPluginConfig(t.TempDir(), false)
	cfg.Plugins.TrustedPublishers = map[string]string{keyID: pub}
	installer := NewPluginPackageInstaller(cfg, PluginHostInfo{Version: "0.2.19", BuildType: "source"})
	file, err := os.Open(pkg)
	require.NoError(t, err)
	defer func() { _ = file.Close() }()
	installation, err := installer.Install(context.Background(), file, nil)
	require.NoError(t, err)
	require.Equal(t, PluginSignatureTrusted, installation.SignatureStatus)
	require.Equal(t, PluginStateDisabled, installation.State, "初次安装必须保持停用")
	// 宿主按清单创建绑定；派生包只能声明一个 API Key 能力，启用后不会同时打开 OAuth。
	require.Len(t, installation.Manifest.Capabilities, 1)
	require.Equal(t, PluginCapabilityOpenAIAPIKeyOutbound, installation.Manifest.Capabilities[0].ID)
	require.Equal(t, AccountTypeAPIKey, installation.Manifest.Capabilities[0].AccountType)
	require.Equal(t, PlatformOpenAI, installation.Manifest.Capabilities[0].Platform)
	compatibility := EvaluatePluginCompatibility(installation.Manifest, PluginHostInfo{Version: "0.2.19"})
	require.True(t, compatibility.Compatible, compatibility.Message)
	require.True(t, compatibility.Tested, compatibility.Message)
	return installation
}

func startAPIKeyPluginRuntime(t *testing.T, installation *PluginInstallation, configJSON string) *pluginRuntime {
	t.Helper()
	runtime, err := startPluginRuntime(context.Background(), installation, 10*time.Second, filepath.Join(t.TempDir(), "runtime"), nil)
	require.NoError(t, err)
	require.NoError(t, runtime.validateAndApplyConfig(context.Background(), []byte(configJSON)))
	t.Cleanup(runtime.kill)
	return runtime
}

type timedRecord struct {
	start time.Time
	buf   bytes.Buffer
	marks map[string]time.Duration
}

func newTimedRecord() *timedRecord {
	return &timedRecord{start: time.Now(), marks: map[string]time.Duration{}}
}

func (w *timedRecord) Write(p []byte) (int, error) {
	_, _ = w.buf.Write(p)
	for _, marker := range []string{"sub2api.timing", "Hello", `"usage"`} {
		if _, seen := w.marks[marker]; !seen && bytes.Contains(p, []byte(marker)) {
			w.marks[marker] = time.Since(w.start)
		}
	}
	return len(p), nil
}

func apiKeyPluginRoundTrip(t *testing.T, runtime *pluginRuntime, upstreamURL, body string) (*http.Response, *timedRecord, error) {
	t.Helper()
	request, err := http.NewRequestWithContext(context.Background(), http.MethodPost, upstreamURL+"/v1/responses", strings.NewReader(body))
	require.NoError(t, err)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer fixture-key")
	// 计时必须从发起请求开始，而不是从收到响应头开始：提示可能先于响应头到达。
	record := newTimedRecord()
	require.True(t, runtime.beginRequest())
	response, err := runtime.roundTrip(context.Background(), request, "", &Account{ID: 42, Platform: PlatformOpenAI, Type: AccountTypeAPIKey, Concurrency: 1})
	if err != nil {
		runtime.finishRequest()
		return nil, nil, err
	}
	_, copyErr := io.Copy(record, response.Body)
	runtime.finishRequest()
	_ = response.Body.Close()
	return response, record, copyErr
}

const apiKeyPluginStreamBody = `event: response.created
data: {"type":"response.created","response":{"id":"resp_fixture","status":"in_progress"}}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"Hello"}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_fixture","usage":{"input_tokens":11,"output_tokens":7,"total_tokens":18}}}

`

func TestAPIKeyPluginStreamNeedsRealProcess(t *testing.T) {
	pkg, keyID, pub := apiKeyPluginTestEnv(t)
	installation := installAPIKeyPlugin(t, pkg, keyID, pub)

	var firstTokenAt atomic.Int64
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.True(t, strings.HasSuffix(strings.TrimRight(r.URL.Path, "/"), "/responses"))
		body, readErr := io.ReadAll(r.Body)
		require.NoError(t, readErr)
		require.JSONEq(t, `{"model":"fixture-model","stream":true}`, string(body))
		require.Equal(t, "Bearer fixture-key", r.Header.Get("Authorization"))
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		flusher, _ := w.(http.Flusher)
		if flusher != nil {
			flusher.Flush()
		}
		// 先发响应头，再等待真实首 token；这正是插件提示要提前填补的等待窗口。
		time.Sleep(400 * time.Millisecond)
		firstTokenAt.Store(time.Now().UnixNano())
		_, _ = io.WriteString(w, apiKeyPluginStreamBody)
		if flusher != nil {
			flusher.Flush()
		}
	}))
	defer upstream.Close()

	runtime := startAPIKeyPluginRuntime(t, installation, `{"mode":"hint","hint_after_ms":100,"retry_max_attempts":0}`)
	before := time.Now()
	response, record, err := apiKeyPluginRoundTrip(t, runtime, upstream.URL, `{"model":"fixture-model","stream":true}`)
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, response.StatusCode)
	require.Equal(t, "text/event-stream", response.Header.Get("Content-Type"))
	require.Less(t, time.Since(before), 5*time.Second)

	got := record.buf.String()
	require.Contains(t, got, "sub2api.timing", "提前提示必须真实发出")
	require.Contains(t, got, `"delta":"Hello"`, "真实文本必须保留")
	require.Contains(t, got, `"input_tokens":11`, "完成事件里的 usage 必须保留")
	require.Contains(t, got, `"output_tokens":7`)

	// 提示必须早于上游首 token，且是空 delta（不是伪造的模型文本）。
	hintAt, realAt := record.marks["sub2api.timing"], record.marks["Hello"]
	require.NotZero(t, hintAt)
	require.NotZero(t, realAt)
	require.Less(t, hintAt, realAt, "提示=%s 真实首字=%s", hintAt, realAt)
	t.Logf("hint_at=%s real_first_token_at=%s total_bytes=%d", hintAt, realAt, len(got))
	require.Contains(t, got, "event: sub2api.timing\ndata: {\"type\":\"sub2api.timing\",\"delta\":\"\"}")

	// 用量对照：插件不得改写上游 usage 数值。
	var lastUsage gjson.Result
	for _, line := range strings.Split(got, "\n") {
		payload := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "data:"))
		if gjson.Valid(payload) && gjson.Get(payload, "response.usage").Exists() {
			lastUsage = gjson.Get(payload, "response.usage")
		}
	}
	require.True(t, lastUsage.Exists(), "交付流里必须能看到上游 usage")
	require.Equal(t, int64(11), lastUsage.Get("input_tokens").Int())
	require.Equal(t, int64(7), lastUsage.Get("output_tokens").Int())
	require.Equal(t, int64(18), lastUsage.Get("total_tokens").Int())
}

func TestAPIKeyPluginModeOffPreservesStream(t *testing.T) {
	pkg, keyID, pub := apiKeyPluginTestEnv(t)
	installation := installAPIKeyPlugin(t, pkg, keyID, pub)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, apiKeyPluginStreamBody)
	}))
	defer upstream.Close()

	runtime := startAPIKeyPluginRuntime(t, installation, `{"mode":"off"}`)
	response, record, err := apiKeyPluginRoundTrip(t, runtime, upstream.URL, `{"model":"fixture-model","stream":true}`)
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, response.StatusCode)
	got := record.buf.String()
	require.Equal(t, apiKeyPluginStreamBody, got, "mode=off 必须逐字节透传，不改写流")
	require.NotContains(t, got, "sub2api.timing")
}

func TestAPIKeyPluginNonStreamAndErrorPaths(t *testing.T) {
	pkg, keyID, pub := apiKeyPluginTestEnv(t)
	installation := installAPIKeyPlugin(t, pkg, keyID, pub)

	t.Run("non_stream_passthrough", func(t *testing.T) {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, `{"id":"resp_1","usage":{"input_tokens":3,"output_tokens":2}}`)
		}))
		defer upstream.Close()
		runtime := startAPIKeyPluginRuntime(t, installation, `{"mode":"hint","hint_after_ms":50}`)
		response, record, err := apiKeyPluginRoundTrip(t, runtime, upstream.URL, `{"model":"fixture-model","stream":false}`)
		require.NoError(t, err)
		require.Equal(t, http.StatusOK, response.StatusCode)
		require.Equal(t, `{"id":"resp_1","usage":{"input_tokens":3,"output_tokens":2}}`, record.buf.String())
	})

	// 已知缺陷（原版 0.1.4-am1.1）：提示已发出后上游返回 503 JSON，且正文含 usage，
	// 错误包装会丢掉 usage。这里把现状固化成断言，避免把安装验签成功当成计费正确。
	t.Run("late_http_error_drops_usage_known_defect", func(t *testing.T) {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// 延迟发送响应头，让插件的提示先发出；随后上游才返回 503 JSON。
			time.Sleep(300 * time.Millisecond)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = io.WriteString(w, `{"error":{"code":"server_error","message":"overloaded"},"usage":{"input_tokens":5,"output_tokens":0,"total_tokens":5}}`)
		}))
		defer upstream.Close()
		runtime := startAPIKeyPluginRuntime(t, installation, `{"mode":"hint","hint_after_ms":50,"retry_max_attempts":0}`)
		response, record, err := apiKeyPluginRoundTrip(t, runtime, upstream.URL, `{"model":"fixture-model","stream":true}`)
		require.NoError(t, err)
		require.Equal(t, http.StatusOK, response.StatusCode, "提示先提交了 200，之后的上游失败只能表达为流内失败")
		got := record.buf.String()
		require.Contains(t, got, "sub2api.timing")
		require.Contains(t, got, "response.failed")
		require.Contains(t, got, `"status_code":503`)
		require.NotContains(t, got, `"input_tokens":5`, "原版已知缺陷：提示后晚到错误会丢掉 usage")
	})

	// 对照：提示尚未发出时的 503 JSON 逐字节透传，usage 不丢失。缺陷只在提示后路径。
	t.Run("early_http_error_keeps_usage", func(t *testing.T) {
		errorBody := `{"error":{"code":"server_error","message":"overloaded"},"usage":{"input_tokens":5,"output_tokens":0,"total_tokens":5}}`
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = io.WriteString(w, errorBody)
		}))
		defer upstream.Close()
		runtime := startAPIKeyPluginRuntime(t, installation, `{"mode":"hint","hint_after_ms":500,"retry_max_attempts":0}`)
		response, record, err := apiKeyPluginRoundTrip(t, runtime, upstream.URL, `{"model":"fixture-model","stream":true}`)
		require.NoError(t, err)
		require.Equal(t, http.StatusServiceUnavailable, response.StatusCode)
		require.Equal(t, errorBody, record.buf.String())
		require.NotContains(t, record.buf.String(), "sub2api.timing")
	})
}

func TestAPIKeyPluginCancelPropagates(t *testing.T) {
	pkg, keyID, pub := apiKeyPluginTestEnv(t)
	installation := installAPIKeyPlugin(t, pkg, keyID, pub)

	upstreamSawCancel := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		flusher, _ := w.(http.Flusher)
		_, _ = io.WriteString(w, "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_cancel\"}}\n\n")
		if flusher != nil {
			flusher.Flush()
		}
		select {
		case <-r.Context().Done():
			close(upstreamSawCancel)
		case <-time.After(3 * time.Second):
		}
	}))
	defer upstream.Close()

	runtime := startAPIKeyPluginRuntime(t, installation, `{"mode":"hint","hint_after_ms":40,"retry_max_attempts":0}`)
	ctx, cancel := context.WithCancel(context.Background())
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, upstream.URL+"/v1/responses", strings.NewReader(`{"model":"fixture-model","stream":true}`))
	require.NoError(t, err)
	require.True(t, runtime.beginRequest())
	response, err := runtime.roundTrip(ctx, request, "", &Account{ID: 7, Platform: PlatformOpenAI, Type: AccountTypeAPIKey})
	runtime.finishRequest()
	require.NoError(t, err)
	buffer := make([]byte, 64)
	_, _ = response.Body.Read(buffer)
	cancel()
	_ = response.Body.Close()
	select {
	case <-upstreamSawCancel:
	case <-time.After(3 * time.Second):
		t.Fatal("上游没有收到取消，插件可能吞掉了下游断开")
	}
}

// 原版包含有限重试：同一账号、在首个真实输出之前、对明确 503 重发一次。这里验证
// 它确实存在，避免声称插件“只改显示”。
func TestAPIKeyPluginRetriesOverloadBeforeOutput(t *testing.T) {
	pkg, keyID, pub := apiKeyPluginTestEnv(t)
	installation := installAPIKeyPlugin(t, pkg, keyID, pub)

	var attempts atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempt := attempts.Add(1)
		w.Header().Set("Content-Type", "application/json")
		if attempt == 1 {
			time.Sleep(150 * time.Millisecond)
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = io.WriteString(w, `{"error":{"code":"server_error","message":"Our servers are currently overloaded. Please try again later."}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, apiKeyPluginStreamBody)
	}))
	defer upstream.Close()

	runtime := startAPIKeyPluginRuntime(t, installation, `{"mode":"hint","hint_after_ms":50,"retry_max_attempts":2,"retry_backoff_ms":50,"retry_total_wait_ms":3000}`)
	response, record, err := apiKeyPluginRoundTrip(t, runtime, upstream.URL, `{"model":"fixture-model","stream":true}`)
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, response.StatusCode)
	require.Equal(t, int32(2), attempts.Load(), "插件应在输出前对过载做一次同账号重试")
	require.Contains(t, record.buf.String(), `"delta":"Hello"`)
	require.Equal(t, 1, strings.Count(record.buf.String(), "event: sub2api.timing"), "重试后仍只发一次提示")
}
