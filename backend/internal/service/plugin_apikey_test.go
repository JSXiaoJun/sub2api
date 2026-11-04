package service

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func keyPluginRequest(t *testing.T, method, path, body string) *http.Request {
	t.Helper()
	r, err := http.NewRequest(method, "https://example.com"+path, strings.NewReader(body))
	require.NoError(t, err)
	return markOpenAIAPIKeyPluginStream(r, []byte(body))
}

func TestAPIKeyPluginRoutingIsExplicitAndScoped(t *testing.T) {
	for _, tt := range []struct {
		name, platform, typ, method, path, body string
		keyRollout, oauthRollout                int
		wantHandled                             bool
	}{
		{"key_stream", PlatformOpenAI, AccountTypeAPIKey, "POST", "/v1/responses", `{"stream":true}`, 100, 0, true},
		{"key_nonstream", PlatformOpenAI, AccountTypeAPIKey, "POST", "/v1/responses", `{"stream":false}`, 100, 0, false},
		{"key_missing_stream", PlatformOpenAI, AccountTypeAPIKey, "POST", "/v1/responses", `{}`, 100, 0, false},
		{"key_string_stream", PlatformOpenAI, AccountTypeAPIKey, "POST", "/v1/responses", `{"stream":"true"}`, 100, 0, false},
		{"key_chat", PlatformOpenAI, AccountTypeAPIKey, "POST", "/v1/chat/completions", `{"stream":true}`, 100, 0, false},
		{"key_embeddings", PlatformOpenAI, AccountTypeAPIKey, "POST", "/v1/embeddings", `{"stream":true}`, 100, 0, false},
		{"key_images", PlatformOpenAI, AccountTypeAPIKey, "POST", "/v1/images/generations", `{"stream":true}`, 100, 0, false},
		{"key_compact", PlatformOpenAI, AccountTypeAPIKey, "POST", "/v1/responses/compact", `{"stream":true}`, 100, 0, false},
		{"key_get", PlatformOpenAI, AccountTypeAPIKey, "GET", "/v1/responses", `{"stream":true}`, 100, 0, false},
		{"key_disabled", PlatformOpenAI, AccountTypeAPIKey, "POST", "/v1/responses", `{"stream":true}`, 0, 100, false},
		{"oauth_not_implied", PlatformOpenAI, AccountTypeOAuth, "POST", "/v1/responses", `{"stream":true}`, 100, 0, false},
		{"oauth_preserved", PlatformOpenAI, AccountTypeOAuth, "POST", "/v1/responses", `{}`, 0, 100, true},
		{"other_provider", PlatformAnthropic, AccountTypeAPIKey, "POST", "/v1/responses", `{"stream":true}`, 100, 100, false},
		{"setup_token", PlatformOpenAI, AccountTypeSetupToken, "POST", "/v1/responses", `{"stream":true}`, 100, 100, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			m := &PluginManager{}
			m.route.Store(&pluginRoute{pluginID: 1, apiKeyRolloutPercent: tt.keyRollout, rolloutPercent: tt.oauthRollout, unavailable: "fixture"})
			r := keyPluginRequest(t, tt.method, tt.path, tt.body)
			a := &Account{ID: 9, Platform: tt.platform, Type: tt.typ}
			response, handled, err := m.RoundTripOpenAIOutbound(r.Context(), r, "", a)
			require.Nil(t, response)
			require.Equal(t, tt.wantHandled, handled)
			if handled {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
			}
			body, readErr := io.ReadAll(r.Body)
			require.NoError(t, readErr)
			require.Equal(t, tt.body, string(body), "routing must not consume request body")
			if tt.typ == AccountTypeAPIKey {
				require.False(t, m.ShouldRouteOpenAIOAuth(a), "native WS routing must remain unchanged")
			}
		})
	}
}

func TestAPIKeyPluginRequiresPrivateStreamMarker(t *testing.T) {
	m := &PluginManager{}
	m.route.Store(&pluginRoute{apiKeyRolloutPercent: 100, unavailable: "fixture"})
	r, _ := http.NewRequest("POST", "https://example.com/v1/responses", strings.NewReader(`{"stream":true}`))
	r.Header.Set("Accept", "text/event-stream")
	r.Header.Set("X-Sub2API-Stream", "true")
	_, handled, err := m.RoundTripOpenAIOutbound(r.Context(), r, "", &Account{ID: 1, Platform: PlatformOpenAI, Type: AccountTypeAPIKey})
	require.False(t, handled)
	require.NoError(t, err)
}

func TestAPIKeyPluginRetainsPublicHostRestriction(t *testing.T) {
	m := &PluginManager{}
	m.route.Store(&pluginRoute{apiKeyRolloutPercent: 100, unavailable: "must not reach runtime"})
	r, _ := http.NewRequestWithContext(WithHTTPUpstreamPublicHostsOnly(context.Background()), "POST", "http://127.0.0.1/v1/responses", strings.NewReader(`{"stream":true}`))
	r = markOpenAIAPIKeyPluginStream(r, []byte(`{"stream":true}`))
	_, handled, err := m.RoundTripOpenAIOutbound(r.Context(), r, "", &Account{ID: 1, Platform: PlatformOpenAI, Type: AccountTypeAPIKey})
	require.True(t, handled)
	require.Error(t, err)
	require.NotContains(t, err.Error(), "must not reach runtime")
}

// 只有原生 Responses 入口生成的出站请求才会带 API Key 插件标记；Chat Completions、
// Anthropic Messages、图像等入口转换到 /responses 的桥接请求必须保持原路径。
func TestAPIKeyPluginActualRequestBuildersMarkOnlyNativeResponses(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, tt := range []struct {
		downstream string
		body       string
	}{
		{"/v1/responses", `{"model":"fixture","stream":true}`},
		{"/v1/responses", `{"model":"fixture","stream":false}`},
		{"/v1/chat/completions", `{"model":"fixture","stream":true}`},
		{"/v1/messages", `{"model":"fixture","stream":true}`},
	} {
		svc := &OpenAIGatewayService{cfg: &config.Config{}}
		c, _ := gin.CreateTestContext(httptest.NewRecorder())
		c.Request = httptest.NewRequest("POST", tt.downstream, strings.NewReader(tt.body))
		a := &Account{ID: 1, Platform: PlatformOpenAI, Type: AccountTypeAPIKey}
		native := tt.downstream == "/v1/responses"
		want := native && strings.Contains(tt.body, `"stream":true`)
		standard, err := svc.buildUpstreamRequest(context.Background(), c, a, []byte(tt.body), "fixture-key", strings.Contains(tt.body, `"stream":true`), "", false)
		require.NoError(t, err)
		passthrough, err := svc.buildUpstreamRequestOpenAIPassthrough(context.Background(), c, a, []byte(tt.body), "fixture-key")
		require.NoError(t, err)
		for _, r := range []*http.Request{standard, passthrough} {
			require.Equal(t, want, isOpenAIAPIKeyPluginStream(r), "downstream=%s body=%s", tt.downstream, tt.body)
			require.Equal(t, "Bearer fixture-key", r.Header.Get("Authorization"))
			got, err := io.ReadAll(r.Body)
			require.NoError(t, err)
			require.Equal(t, tt.body, string(got))
		}
	}
}

func TestAPIKeyPluginBindingAndDirectoryIsolation(t *testing.T) {
	key := PluginBinding{Enabled: true, Capability: PluginCapabilityOpenAIAPIKeyOutbound, Platform: PlatformOpenAI, AccountType: AccountTypeAPIKey, RolloutPercent: 37}
	require.Equal(t, 0, bindingRollout([]PluginBinding{key}))
	require.Equal(t, 37, apiKeyBindingRollout([]PluginBinding{key}))
	require.True(t, hasEnabledOpenAIBinding([]PluginBinding{key}))
	key.RolloutPercent = 0
	require.False(t, hasEnabledOpenAIBinding([]PluginBinding{key}), "0% rollout must not count as enabled routing")
	key.RolloutPercent = 37
	key.Enabled = false
	require.False(t, hasEnabledOpenAIBinding([]PluginBinding{key}))
	key.Enabled, key.AccountType = true, AccountTypeOAuth
	require.False(t, hasEnabledOpenAIBinding([]PluginBinding{key}))

	m := testPluginManifest(nil)
	m.Capabilities = []PluginCapability{{ID: PluginCapabilityOpenAIAPIKeyOutbound, Platform: PlatformOpenAI, AccountType: AccountTypeAPIKey}}
	require.NoError(t, m.Validate())
	require.True(t, pluginAccountScopeFromManifest(m).Empty(), "API Key transport must not grant credential enumeration")
	m.Capabilities[0].AccountType = AccountTypeOAuth
	require.Error(t, m.Validate())
	m.Capabilities[0].AccountType, m.Capabilities[0].Platform = AccountTypeAPIKey, PlatformAnthropic
	require.Error(t, m.Validate())
	m.Capabilities = []PluginCapability{
		{ID: PluginCapabilityOpenAIAPIKeyOutbound, Platform: PlatformOpenAI, AccountType: AccountTypeAPIKey},
		{ID: PluginCapabilityOpenAIOAuthOutbound, Platform: PlatformOpenAI, AccountType: AccountTypeOAuth},
	}
	require.NoError(t, m.Validate(), "a package may declare both bindings; scoping happens at install time")
	scope := pluginAccountScopeFromManifest(m)
	require.False(t, scope.Empty(), "the OAuth binding still grants its own account type")
	require.True(t, scope.Contains(PlatformOpenAI, AccountTypeOAuth))
	require.False(t, scope.Contains(PlatformOpenAI, AccountTypeAPIKey), "the API Key binding must not open the account directory")
}

type keyPluginFailingRepo struct{ PluginRepository }

func (*keyPluginFailingRepo) List(context.Context) ([]*PluginInstallation, error) {
	return nil, errors.New("offline fixture")
}

func TestAPIKeyPluginFailurePathsPreserveAccountScope(t *testing.T) {
	for _, keyRollout := range []int{0, 37, 100} {
		m := &PluginManager{repo: &keyPluginFailingRepo{}, runtimes: make(map[int64]*pluginRuntime)}
		route := &pluginRoute{pluginID: 7, rolloutPercent: 12, apiKeyRolloutPercent: keyRollout}
		m.route.Store(route)
		require.NoError(t, m.markRuntimeUnavailable(route, "crash"))
		require.Equal(t, keyRollout, m.route.Load().apiKeyRolloutPercent)
		require.Equal(t, 12, m.route.Load().rolloutPercent)
		require.Error(t, m.reconcileOnce(context.Background()))
		require.Equal(t, keyRollout, m.route.Load().apiKeyRolloutPercent)
		m.detachAllRuntimes()
		require.Nil(t, m.route.Load())
	}
	m := &PluginManager{repo: &keyPluginFailingRepo{}, runtimes: make(map[int64]*pluginRuntime)}
	require.Error(t, m.reconcileOnce(context.Background()))
	require.Equal(t, 0, m.route.Load().apiKeyRolloutPercent, "unknown database state must not opt Key accounts in")
}

func TestAPIKeyPluginRolloutDeterministicAndNativeFallback(t *testing.T) {
	m := &PluginManager{}
	m.route.Store(&pluginRoute{apiKeyRolloutPercent: 37, unavailable: "fixture"})
	upstream := &pluginRoutingHTTPUpstream{}
	svc := &OpenAIGatewayService{pluginManager: m, httpUpstream: upstream}
	for id := int64(1); id <= 200; id++ {
		r := keyPluginRequest(t, "POST", "/v1/responses", `{"stream":true}`)
		a := &Account{ID: id, Platform: PlatformOpenAI, Type: AccountTypeAPIKey}
		resp, err := svc.doOpenAIUpstream(r, "", a)
		if stablePluginBucket(id) < 37 {
			require.Error(t, err)
			require.Nil(t, resp)
		} else {
			require.NoError(t, err)
			require.NotNil(t, resp)
			_ = resp.Body.Close()
		}
	}
	require.Positive(t, upstream.doCalls)
	m.route.Store(nil)
	r := keyPluginRequest(t, "POST", "/v1/responses", `{"stream":true}`)
	resp, err := svc.doOpenAIUpstream(r, "", &Account{ID: 1, Platform: PlatformOpenAI, Type: AccountTypeAPIKey})
	require.NoError(t, err)
	_ = resp.Body.Close()
}
