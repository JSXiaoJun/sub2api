package service

import (
	"context"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/tidwall/gjson"
)

func (s *OpenAIGatewayService) SetPluginManager(manager *PluginManager) {
	s.pluginManager = manager
}

// doOpenAIUpstream 仅把命中显式绑定的 OAuth 或 API Key 流式 Responses 请求交给插件。
// 插件返回标准 http.Response，响应解析、错误映射、SSE 和计费仍由现有核心链处理。
func (s *OpenAIGatewayService) doOpenAIUpstream(request *http.Request, proxyURL string, account *Account) (*http.Response, error) {
	if s.pluginManager != nil {
		response, handled, err := s.pluginManager.RoundTripOpenAIOutbound(request.Context(), request, proxyURL, account)
		if handled {
			return response, err
		}
	}
	return s.httpUpstream.Do(request, proxyURL, account.ID, account.Concurrency)
}

// doOpenAIAccountTestUpstream 让命中绑定的账号测试与真实转发使用同一插件路径。
// 未命中插件的账号保持各自原有的 HTTPUpstream 行为。
func (s *AccountTestService) doOpenAIAccountTestUpstream(
	request *http.Request,
	proxyURL string,
	account *Account,
	useTLSFallback bool,
) (*http.Response, error) {
	if s.pluginManager != nil {
		response, handled, err := s.pluginManager.RoundTripOpenAIOutbound(request.Context(), request, proxyURL, account)
		if handled {
			return response, err
		}
	}
	if useTLSFallback {
		return s.httpUpstream.DoWithTLS(
			request,
			proxyURL,
			account.ID,
			account.Concurrency,
			s.tlsFPProfileService.ResolveTLSProfile(account),
		)
	}
	return s.httpUpstream.Do(request, proxyURL, account.ID, account.Concurrency)
}

type openAIAPIKeyPluginStreamKey struct{}

// markOpenAIAPIKeyPluginStream 把「真实出站请求体是否为流式」这一事实固化到私有
// context。它不读取、缓冲或消费 HTTP 请求体，也不向上下游暴露任何标记。
func markOpenAIAPIKeyPluginStream(request *http.Request, body []byte) *http.Request {
	stream := gjson.GetBytes(body, "stream")
	return request.WithContext(context.WithValue(request.Context(), openAIAPIKeyPluginStreamKey{}, stream.Type == gjson.True))
}

// markOpenAIAPIKeyPluginStreamFromGin 只给原生 Responses 入口生成的出站请求打标。
// Sub2API 还会把 Chat Completions、Anthropic Messages、图像等入口转换成
// POST /responses 的流式请求；这些桥接接口不属于本插件的适配范围，不能顺带改变
// 它们的首字、重试和错误语义。
func markOpenAIAPIKeyPluginStreamFromGin(c *gin.Context, request *http.Request, body []byte) *http.Request {
	if c == nil || c.Request == nil || c.Request.URL == nil || !isOpenAIResponsesEntryPath(c.Request.URL.Path) {
		return request
	}
	return markOpenAIAPIKeyPluginStream(request, body)
}

func isOpenAIResponsesEntryPath(path string) bool {
	trimmed := strings.TrimRight(path, "/")
	return trimmed == "/v1/responses" || trimmed == "/responses"
}

func isOpenAIAPIKeyPluginStream(request *http.Request) bool {
	if request == nil || request.URL == nil || request.Method != http.MethodPost || !strings.HasSuffix(strings.TrimRight(request.URL.Path, "/"), "/responses") {
		return false
	}
	stream, _ := request.Context().Value(openAIAPIKeyPluginStreamKey{}).(bool)
	return stream
}
