-- 插件出站绑定的账号分组范围。
-- all_groups 缺省为 TRUE，保留旧行为（所有匹配账号）；
-- group_ids 仅在 all_groups = FALSE 时生效，表示只对绑定到这些账号分组的账号启用插件。
-- 分组删除后残留的 ID 不会匹配任何账号，只会收窄范围，不会扩大权限。

ALTER TABLE sub2api_plugin_bindings
    ADD COLUMN IF NOT EXISTS all_groups BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS group_ids BIGINT[] NOT NULL DEFAULT '{}'::bigint[];

COMMENT ON COLUMN sub2api_plugin_bindings.all_groups IS
    'TRUE: 所有匹配账号类型/平台的账号；FALSE: 仅 group_ids 中的账号分组';
COMMENT ON COLUMN sub2api_plugin_bindings.group_ids IS
    '账号分组 ID 列表；仅 all_groups = FALSE 时参与路由判断';
