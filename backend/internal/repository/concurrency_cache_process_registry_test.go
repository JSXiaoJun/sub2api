package repository

import (
	"context"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/require"
)

type processRegistryFixture struct {
	t      *testing.T
	ctx    context.Context
	server *miniredis.Miniredis
	client *redis.Client
	cache  *concurrencyCache
}

func newProcessRegistryFixture(t *testing.T) *processRegistryFixture {
	t.Helper()
	server := miniredis.RunT(t)
	server.SetTime(time.Unix(1_800_000_000, 0))
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { _ = client.Close() })
	ctx := context.Background()
	// 隔离一次性遗留清扫，只验证登记表驱动的清理。
	require.NoError(t, client.Set(ctx, legacyWaitSweepMarkerKey, "1", 0).Err())
	cache, ok := NewConcurrencyCache(client, 15, 900).(*concurrencyCache)
	require.True(t, ok, "NewConcurrencyCache must return *concurrencyCache")
	return &processRegistryFixture{
		t:      t,
		ctx:    ctx,
		server: server,
		client: client,
		cache:  cache,
	}
}

func (f *processRegistryFixture) advance(d time.Duration) {
	f.t.Helper()
	now, err := f.cache.redisUnixSeconds(f.ctx)
	require.NoError(f.t, err)
	f.server.SetTime(time.Unix(now, 0).Add(d))
}

func (f *processRegistryFixture) acquire(accountID, userID int64, requestID string) {
	f.t.Helper()
	ok, err := f.cache.AcquireAccountSlot(f.ctx, accountID, 100, requestID)
	require.NoError(f.t, err)
	require.True(f.t, ok)
	ok, err = f.cache.AcquireUserSlot(f.ctx, userID, 100, requestID)
	require.NoError(f.t, err)
	require.True(f.t, ok)
}

func (f *processRegistryFixture) accountMembers(accountID int64) []string {
	f.t.Helper()
	members, err := f.client.ZRange(f.ctx, accountSlotKey(accountID), 0, -1).Result()
	require.NoError(f.t, err)
	return members
}

func (f *processRegistryFixture) userMembers(userID int64) []string {
	f.t.Helper()
	members, err := f.client.ZRange(f.ctx, userSlotKey(userID), 0, -1).Result()
	require.NoError(f.t, err)
	return members
}

func (f *processRegistryFixture) registryMembers() []string {
	f.t.Helper()
	members, err := f.client.ZRange(f.ctx, processRegistryKey, 0, -1).Result()
	require.NoError(f.t, err)
	return members
}

// 蓝绿部署：新槽位启动时，仍在服务的旧槽位的在途请求不能被清掉。
func TestCleanupStaleProcessSlots_KeepsSlotsOfLiveOtherProcess(t *testing.T) {
	f := newProcessRegistryFixture(t)

	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rblue", "sub2api-blue:8080"))
	f.acquire(1, 2, "rblue-1")
	f.acquire(1, 2, "rcrashed-1")

	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rgreen", "sub2api-green:8080"))
	f.acquire(1, 2, "rgreen-1")
	require.NoError(t, f.cache.CleanupStaleProcessSlots(f.ctx, "rgreen"))

	require.ElementsMatch(t, []string{"rblue-1", "rgreen-1"}, f.accountMembers(1))
	require.ElementsMatch(t, []string{"rblue-1", "rgreen-1"}, f.userMembers(2))
	require.ElementsMatch(t,
		[]string{"rblue|sub2api-blue:8080", "rgreen|sub2api-green:8080"},
		f.registryMembers(),
	)

	count, err := f.cache.GetAccountConcurrency(f.ctx, 1)
	require.NoError(t, err)
	require.Equal(t, 2, count)
}

// 心跳过期的进程视为已死：它的槽位和登记项都被回收。
func TestCleanupStaleProcessSlots_ReclaimsProcessWithExpiredHeartbeat(t *testing.T) {
	f := newProcessRegistryFixture(t)

	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rdead", "host-a:8080"))
	f.acquire(1, 2, "rdead-1")

	f.advance(service.ConcurrencyProcessLivenessTTL + time.Second)
	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rnew", "host-b:8080"))
	f.acquire(1, 2, "rnew-1")
	require.NoError(t, f.cache.CleanupStaleProcessSlots(f.ctx, "rnew"))

	require.Equal(t, []string{"rnew-1"}, f.accountMembers(1))
	require.Equal(t, []string{"rnew-1"}, f.userMembers(2))
	require.Equal(t, []string{"rnew|host-b:8080"}, f.registryMembers())
}

// 单实例崩溃后在同一个容器里重启：前身的心跳还没过期，但实例标识相同，必须立即回收。
func TestCleanupStaleProcessSlots_ReclaimsPredecessorOnSameInstance(t *testing.T) {
	f := newProcessRegistryFixture(t)

	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rold", "sub2api:8080"))
	f.acquire(1, 2, "rold-1")
	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rother", "sub2api-green:8080"))
	f.acquire(1, 2, "rother-1")

	f.advance(5 * time.Second)
	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rnew", "sub2api:8080"))
	require.NoError(t, f.cache.CleanupStaleProcessSlots(f.ctx, "rnew"))

	require.Equal(t, []string{"rother-1"}, f.accountMembers(1))
	require.Equal(t, []string{"rother-1"}, f.userMembers(2))
	require.ElementsMatch(t,
		[]string{"rnew|sub2api:8080", "rother|sub2api-green:8080"},
		f.registryMembers(),
	)
}

// 没有登记表（旧版本遗留的 Redis 数据）时保持原行为：只留当前进程前缀。
func TestCleanupStaleProcessSlots_WithoutRegistryKeepsOnlyOwnPrefix(t *testing.T) {
	f := newProcessRegistryFixture(t)

	f.acquire(1, 2, "rlegacy-1")
	f.acquire(1, 2, "rself-1")
	require.NoError(t, f.cache.CleanupStaleProcessSlots(f.ctx, "rself"))

	require.Equal(t, []string{"rself-1"}, f.accountMembers(1))
	require.Equal(t, []string{"rself-1"}, f.userMembers(2))
}

func TestHeartbeatProcess_PrunesExpiredEntries(t *testing.T) {
	f := newProcessRegistryFixture(t)

	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rdead", "host-a:8080"))
	f.advance(service.ConcurrencyProcessLivenessTTL + time.Second)
	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rlive", "host-b:8080"))

	require.Equal(t, []string{"rlive|host-b:8080"}, f.registryMembers())
}

// 优雅退出：只释放本进程的槽位并注销，其他实例不受影响，空索引被回收。
func TestReleaseProcessSlotsAndUnregister(t *testing.T) {
	f := newProcessRegistryFixture(t)

	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rblue", "sub2api-blue:8080"))
	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rgreen", "sub2api-green:8080"))
	f.acquire(1, 2, "rblue-1")
	f.acquire(1, 2, "rgreen-1")
	f.acquire(3, 4, "rblue-2")

	require.NoError(t, f.cache.ReleaseProcessSlots(f.ctx, "rblue"))
	require.NoError(t, f.cache.UnregisterProcess(f.ctx, "rblue", "sub2api-blue:8080"))

	require.Equal(t, []string{"rgreen-1"}, f.accountMembers(1))
	require.Equal(t, []string{"rgreen-1"}, f.userMembers(2))
	require.Empty(t, f.accountMembers(3))
	require.Empty(t, f.userMembers(4))
	require.Equal(t, []string{"rgreen|sub2api-green:8080"}, f.registryMembers())

	accountIndex, err := f.client.ZRange(f.ctx, accountActiveIndexKey, 0, -1).Result()
	require.NoError(t, err)
	require.Equal(t, []string{"1"}, accountIndex)
	userIndex, err := f.client.ZRange(f.ctx, userActiveIndexKey, 0, -1).Result()
	require.NoError(t, err)
	require.Equal(t, []string{"2"}, userIndex)
}

// 进程被强杀且容器被重建（实例标识变了）：新实例启动时它的心跳还没过期，槽位被保留；
// 心跳过期后的下一次心跳必须把残留回收掉，并且不动存活进程的等待计数。
func TestHeartbeatProcess_ReclaimsSlotsOnceAProcessIsDetectedDead(t *testing.T) {
	f := newProcessRegistryFixture(t)

	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rkilled", "container-a:8080"))
	f.acquire(1, 2, "rkilled-1")

	f.advance(10 * time.Second)
	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rnew", "container-b:8080"))
	require.NoError(t, f.cache.CleanupStaleProcessSlots(f.ctx, "rnew"))
	f.acquire(1, 2, "rnew-1")
	require.ElementsMatch(t, []string{"rkilled-1", "rnew-1"}, f.accountMembers(1))

	queued, err := f.cache.IncrementAccountWaitCount(f.ctx, 1, 10)
	require.NoError(t, err)
	require.True(t, queued)

	f.advance(service.ConcurrencyProcessLivenessTTL + time.Second)
	require.NoError(t, f.cache.HeartbeatProcess(f.ctx, "rnew", "container-b:8080"))

	require.Equal(t, []string{"rnew-1"}, f.accountMembers(1))
	require.Equal(t, []string{"rnew-1"}, f.userMembers(2))
	require.Equal(t, []string{"rnew|container-b:8080"}, f.registryMembers())
	waiting, err := f.cache.GetAccountWaitingCount(f.ctx, 1)
	require.NoError(t, err)
	require.Equal(t, 1, waiting)
}
