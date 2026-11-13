package service

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestPluginGroupScopeNormalization(t *testing.T) {
	scope, err := newPluginGroupScope(false, []int64{3, 1, 3})
	require.NoError(t, err)
	require.True(t, scope.Selected)
	require.Equal(t, []int64{1, 3}, scope.GroupIDs)

	_, err = newPluginGroupScope(false, nil)
	require.Error(t, err, "selected scope must not be empty")

	_, err = newPluginGroupScope(false, []int64{0})
	require.Error(t, err, "group IDs must be positive")

	all, err := newPluginGroupScope(true, []int64{9})
	require.NoError(t, err)
	require.False(t, all.Selected)
	require.Empty(t, all.GroupIDs, "all-groups scope must drop the explicit list")
}

func TestPluginGroupScopeAllowsSelectedAccountGroups(t *testing.T) {
	scope := pluginGroupScope{Selected: true, GroupIDs: []int64{2, 4}}

	require.True(t, scope.Allows(&Account{GroupIDs: []int64{1, 4}}))
	require.False(t, scope.Allows(&Account{GroupIDs: []int64{1, 3}}))
	require.False(t, scope.Allows(&Account{}))
	require.False(t, scope.Allows(nil))
	require.True(t, scope.Allows(&Account{Groups: []*Group{{ID: 4}}}), "Groups fallback must be honored")

	require.True(t, (pluginGroupScope{}).Allows(&Account{}), "zero value must mean all groups")
}

func TestBindingGroupScopeTreatsLegacyEmptySelectionAsAll(t *testing.T) {
	binding := PluginBinding{
		Enabled: true, Capability: PluginCapabilityOpenAIAPIKeyOutbound,
		Platform: PlatformOpenAI, AccountType: AccountTypeAPIKey,
	}
	require.False(t, bindingGroupScope([]PluginBinding{binding}).Selected,
		"legacy rows without a group selection must keep the previous all-groups behavior")

	binding.GroupIDs = []int64{12, 8, 12}
	scope := bindingGroupScope([]PluginBinding{binding})
	require.True(t, scope.Selected)
	require.Equal(t, []int64{8, 12}, scope.GroupIDs)

	binding.Enabled = false
	require.False(t, bindingGroupScope([]PluginBinding{binding}).Selected,
		"disabled bindings must not define the route scope")
}

func TestAPIKeyPluginRoutingRespectsAccountGroupScope(t *testing.T) {
	m := &PluginManager{}
	m.route.Store(&pluginRoute{
		pluginID:             7,
		rolloutPercent:       100,
		apiKeyRolloutPercent: 100,
		groupScope:           pluginGroupScope{Selected: true, GroupIDs: []int64{7}},
		unavailable:          "fixture",
	})

	r := keyPluginRequest(t, "POST", "/v1/responses", `{"stream":true}`)
	inScope := &Account{ID: 1, Platform: PlatformOpenAI, Type: AccountTypeAPIKey, GroupIDs: []int64{7}}
	_, handled, err := m.RoundTripOpenAIOutbound(r.Context(), r, "", inScope)
	require.True(t, handled)
	require.Error(t, err, "in-scope account must reach the unavailable fixture route")

	outOfScope := &Account{ID: 1, Platform: PlatformOpenAI, Type: AccountTypeAPIKey, GroupIDs: []int64{8}}
	_, handled, err = m.RoundTripOpenAIOutbound(r.Context(), r, "", outOfScope)
	require.False(t, handled)
	require.NoError(t, err, "out-of-scope account must fall back to the native path")

	oauthInScope := &Account{ID: 1, Platform: PlatformOpenAI, Type: AccountTypeOAuth, GroupIDs: []int64{7}}
	require.True(t, m.ShouldRouteOpenAIOAuth(oauthInScope))
	oauthOutOfScope := &Account{ID: 1, Platform: PlatformOpenAI, Type: AccountTypeOAuth, GroupIDs: []int64{8}}
	require.False(t, m.ShouldRouteOpenAIOAuth(oauthOutOfScope))
}

func TestPluginScopeUpdateRequiresEnabledBinding(t *testing.T) {
	repo := &scopeUpdateStubRepository{installation: &PluginInstallation{ID: 3, State: PluginStateDisabled}}
	m := &PluginManager{repo: repo, runtimes: make(map[int64]*pluginRuntime)}
	_, err := m.UpdateScope(context.Background(), 3, 100, false, []int64{5})
	require.Error(t, err)
	require.Contains(t, err.Error(), "请先启用")
}

func TestPluginScopeUpdatePersistsAndRefreshesRouteWithoutRestart(t *testing.T) {
	installation := &PluginInstallation{
		ID: 3, State: PluginStateEnabled, BinarySHA256: "fixture",
		Bindings: []PluginBinding{{
			Enabled: true, Capability: PluginCapabilityOpenAIAPIKeyOutbound,
			Platform: PlatformOpenAI, AccountType: AccountTypeAPIKey,
			RolloutPercent: 100, AllGroups: true,
		}},
	}
	repo := &scopeUpdateStubRepository{installation: installation}
	m := &PluginManager{repo: repo, runtimes: make(map[int64]*pluginRuntime)}
	m.route.Store(&pluginRoute{
		pluginID:             3,
		apiKeyRolloutPercent: 100,
		unavailable:          "fixture",
	})

	updated, err := m.UpdateScope(context.Background(), 3, 37, false, []int64{5, 4, 5})
	require.NoError(t, err)
	require.Len(t, updated.Bindings, 1)
	require.False(t, updated.Bindings[0].AllGroups)
	require.Equal(t, []int64{4, 5}, updated.Bindings[0].GroupIDs)
	require.Equal(t, 37, updated.Bindings[0].RolloutPercent)

	route := m.route.Load()
	require.NotNil(t, route)
	require.True(t, route.groupScope.Selected)
	require.Equal(t, []int64{4, 5}, route.groupScope.GroupIDs)
	require.Equal(t, 37, route.apiKeyRolloutPercent)
}

type scopeUpdateStubRepository struct {
	PluginRepository
	installation *PluginInstallation
}

func (r *scopeUpdateStubRepository) GetByID(context.Context, int64) (*PluginInstallation, error) {
	return r.installation, nil
}

func (r *scopeUpdateStubRepository) UpdateBindingsAndState(
	_ context.Context,
	_ int64,
	bindings []PluginBinding,
	state string,
	_ string,
	enabledAt *time.Time,
	_ string,
	_ string,
) error {
	r.installation.Bindings = append([]PluginBinding(nil), bindings...)
	r.installation.State = state
	r.installation.EnabledAt = enabledAt
	return nil
}
