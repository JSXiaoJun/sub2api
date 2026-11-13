package service

import (
	"errors"
	"fmt"
	"slices"
)

// pluginGroupScope 是插件路由快照中的账号分组过滤器（不可变）。
// 零值表示「全部分组」，因此旧路由与未设置分组范围的绑定保持原有行为。
//
// 判定依据是被调度账号所属的账号分组（Account.GroupIDs），不是请求所属的
// 订阅分组：同一账号如果同时服务多个订阅分组，只要它属于选中账号分组，
// 所有经过该账号的插件请求都会走插件。
type pluginGroupScope struct {
	Selected bool
	GroupIDs []int64
}

func newPluginGroupScope(allGroups bool, groupIDs []int64) (pluginGroupScope, error) {
	if allGroups {
		return pluginGroupScope{}, nil
	}
	normalized, err := normalizePluginGroupIDs(groupIDs)
	if err != nil {
		return pluginGroupScope{}, err
	}
	if len(normalized) == 0 {
		return pluginGroupScope{}, errors.New("请选择至少一个账号分组，或改为全部分组")
	}
	return pluginGroupScope{Selected: true, GroupIDs: normalized}, nil
}

func normalizePluginGroupIDs(groupIDs []int64) ([]int64, error) {
	out := make([]int64, 0, len(groupIDs))
	seen := make(map[int64]struct{}, len(groupIDs))
	for _, groupID := range groupIDs {
		if groupID <= 0 {
			return nil, fmt.Errorf("账号分组 ID 无效: %d", groupID)
		}
		if _, ok := seen[groupID]; ok {
			continue
		}
		seen[groupID] = struct{}{}
		out = append(out, groupID)
	}
	slices.Sort(out)
	return out, nil
}

// Allows 判断被调度账号是否落在当前分组范围内。
func (s pluginGroupScope) Allows(account *Account) bool {
	if !s.Selected {
		return true
	}
	if account == nil {
		return false
	}
	if len(account.GroupIDs) > 0 {
		for _, groupID := range account.GroupIDs {
			if slices.Contains(s.GroupIDs, groupID) {
				return true
			}
		}
		return false
	}
	// 兼容只填充了 Groups、没有填充 GroupIDs 的调用方。
	for _, group := range account.Groups {
		if group != nil && slices.Contains(s.GroupIDs, group.ID) {
			return true
		}
	}
	return false
}

func (s pluginGroupScope) Equal(other pluginGroupScope) bool {
	if s.Selected != other.Selected {
		return false
	}
	if !s.Selected {
		return true
	}
	return slices.Equal(s.GroupIDs, other.GroupIDs)
}

// bindingGroupScope 从安装记录中取出生效的账号分组范围。启用/修改范围时宿主会
// 把所有绑定写成同一份范围，因此取任一已启用的 OpenAI 绑定即可。
func bindingGroupScope(bindings []PluginBinding) pluginGroupScope {
	for _, binding := range bindings {
		if !binding.Enabled || binding.Platform != PlatformOpenAI {
			continue
		}
		if binding.Capability != PluginCapabilityOpenAIOAuthOutbound &&
			binding.Capability != PluginCapabilityOpenAIAPIKeyOutbound {
			continue
		}
		// 旧数据或未显式选择分组时按「全部分组」处理，避免升级后突然收窄到零。
		if binding.AllGroups || len(binding.GroupIDs) == 0 {
			return pluginGroupScope{}
		}
		groupIDs, err := normalizePluginGroupIDs(binding.GroupIDs)
		if err != nil || len(groupIDs) == 0 {
			return pluginGroupScope{}
		}
		return pluginGroupScope{Selected: true, GroupIDs: groupIDs}
	}
	return pluginGroupScope{}
}

func applyPluginGroupScope(bindings []PluginBinding, scope pluginGroupScope) {
	for index := range bindings {
		bindings[index].AllGroups = !scope.Selected
		if scope.Selected {
			bindings[index].GroupIDs = append([]int64(nil), scope.GroupIDs...)
			continue
		}
		bindings[index].GroupIDs = []int64{}
	}
}
