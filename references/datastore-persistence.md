# DataStore & Persistence

> **Source:** [Roblox DataStores](https://create.roblox.com/docs/cloud-services/data-stores) ·
> [Error Codes & Limits](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits) ·
> [Versioning & Caching](https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching)

## Table of Contents
1. [DataStoreService Overview](#datastoreservice-overview)
2. [Core CRUD Operations](#core-crud-operations)
3. [SetAsync vs UpdateAsync](#setasync-vs-updateasync)
4. [Error Handling with pcall](#error-handling-with-pcall)
5. [Rate Limits & Throttling](#rate-limits--throttling)
6. [OrderedDataStore](#ordereddatastore)
7. [Versioning](#versioning)
8. [Storage & Access Limits (Updated April 2026)](#storage--access-limits-updated-april-2026)
9. [ProfileStore (Community Framework)](#profilestore-community-framework)
10. [Data Schema Best Practices](#data-schema-best-practices)
11. [LEGACY](#legacy)

---

## DataStoreService Overview

`DataStoreService` persists data between sessions. Data stores are consistent
per **experience** — every place/server in that experience shares the same data.

**Critical rule:** DataStoreService is **server-side only**. Attempting to access
it from a `LocalScript` throws an error. All DataStore calls must live in `Script`
objects (typically in `ServerScriptService`).

**From an MCP client,** use `DataStoreService` through `execute_luau`, not Open Cloud, and remember
Studio uses the **live** stores: a write changes real player data. It takes the **Save & load data**
scopes in MCP Permissions plus **Game Settings → Security → Enable Studio Access to API Services**.
See `mcp-integration.md`.

```luau
--!strict
-- ServerScriptService/DataManager.server.luau
local DataStoreService = game:GetService("DataStoreService")
local playerStore = DataStoreService:GetDataStore("PlayerData")
```

---

## Core CRUD Operations

### GetAsync — Read
<!-- skilltest: prelude datastore; expect call-succeeded -->
```luau
--!strict
local success, value = pcall(function()
    return playerStore:GetAsync("User_1234")
end)
if success then
    print("Data:", value)
end
```

### SetAsync — Write (simple)
<!-- skilltest: prelude datastore; expect call-succeeded -->
```luau
--!strict
local success, err = pcall(function()
    playerStore:SetAsync("User_1234", { coins = 50, level = 1 })
end)
if not success then
    warn("SetAsync failed:", err)
end
```

### UpdateAsync — Atomic Read-Modify-Write
<!-- skilltest: prelude datastore; expect update-async-increments -->
```luau
--!strict
type PlayerData = { coins: number, level: number }

local success, updatedValue = pcall(function()
    return playerStore:UpdateAsync("User_1234", function(currentData: PlayerData?): PlayerData
        -- The callback must NOT yield (no task.wait, etc.)
        local data: PlayerData = currentData or { coins = 0, level = 1 }
        data.coins += 10
        return data
    end)
end)
```

### RemoveAsync — Delete
<!-- skilltest: prelude datastore; expect call-succeeded -->
```luau
--!strict
local success, oldValue = pcall(function()
    return playerStore:RemoveAsync("User_1234")
end)
```

### IncrementAsync — Atomic Integer Increment
<!-- skilltest: prelude datastore; expect call-succeeded -->
```luau
--!strict
local success, newValue = pcall(function()
    return playerStore:IncrementAsync("User_1234_Visits", 1)
end)
```

---

## SetAsync vs UpdateAsync

| Aspect | SetAsync | UpdateAsync |
|---|---|---|
| **Atomicity** | No — can overwrite concurrent writes from other servers | Yes — reads current value before writing |
| **Speed** | Faster (write only) | Slower (read then write) |
| **Budget cost** | Write limit only | Both read AND write limits |
| **Multi-server safety** | Risk of data inconsistency | Atomic for one key update only (still needs a session lock for active player sessions) |
| **Callback** | N/A | Receives current value, must return new value (or `nil` to cancel) |

**Rule of thumb:** Always prefer `UpdateAsync` for player data, paired with session locking (such as ProfileStore) so an out-of-band update is not overwritten by an active server's next save. Use `SetAsync` only for writes where the new value does not depend on the previous value (e.g., initial seeding, stateless snapshots).

---

## Error Handling with pcall

**All DataStore calls are network requests and can fail.** You MUST wrap every
call in `pcall`. This is not optional.

```luau
--!strict
local MAX_RETRIES = 3
local BASE_RETRY_DELAY = 1
local MAX_RETRY_DELAY = 8

-- Documented non-retryable DataStore error codes (checked 2026-11-26):
-- 101-107 (invalid key/value/range/size), 401-403 (shutdown or Studio API disabled),
-- 509 (blocked private RCC), 511-513 (metadata/UserId format or size errors).
-- Codes 404 and 502 are documented as transient ("Try again later") and must be retried.
local PERMANENT_ERROR_CODES: { [number]: boolean } = {
    [101] = true,
    [102] = true,
    [103] = true,
    [104] = true,
    [105] = true,
    [106] = true,
    [107] = true,
    [401] = true,
    [402] = true,
    [403] = true,
    [509] = true,
    [511] = true,
    [512] = true,
    [513] = true,
}

local function isPermanentError(err: any): boolean
    local codeText = string.match(tostring(err), "^%s*(%d+):")
    local code = if codeText then tonumber(codeText) else nil
    return code ~= nil and PERMANENT_ERROR_CODES[code] == true
end

local function safeGetAsync(store: DataStore, key: string): (boolean, any)
    local lastError: any = nil
    for attempt = 1, MAX_RETRIES do
        local success, result = pcall(function()
            return store:GetAsync(key)
        end)
        if success then
            return true, result
        end
        lastError = result
        warn(`[DataStore] Attempt {attempt} failed: {result}`)
        if isPermanentError(result) then
            return false, result
        end
        if attempt < MAX_RETRIES then
            local backoff = math.min(BASE_RETRY_DELAY * (2 ^ (attempt - 1)), MAX_RETRY_DELAY)
            local jitter = math.random() * 0.5
            task.wait(backoff + jitter)
        end
    end
    return false, lastError
end
```

---

## Rate Limits & Throttling

### Experience-Level Limits (Checked 2026-11-26)

Data stores are subject to both **experience-level and server-level limits** (official [Error Codes & Limits](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits), checked 2026-11-26). Game servers and Open Cloud share the experience-level budgets below.

#### Standard DataStores

| Request Type | Game Server API | Shared Limits (Requests per Minute) |
|---|---|---|
| **Read** | `GetAsync`, `GetVersionAsync`, `GetVersionAtTimeAsync`, `UpdateAsync` | `300 + concurrentUsers × 40` |
| **Write** | `SetAsync`, `IncrementAsync`, `UpdateAsync` | `300 + concurrentUsers × 20` |
| **List** | `ListDataStoresAsync`, `ListKeysAsync`, `ListVersionsAsync` | `300 + concurrentUsers × 2` |
| **Remove** | `RemoveAsync` | `300 + concurrentUsers × 40` |

#### Ordered DataStores

| Request Type | Game Server API | Shared Limits (Requests per Minute) |
|---|---|---|
| **Read** | `GetAsync`, `BatchGetAsync`, `UpdateAsync` | `300 + concurrentUsers × 40` |
| **Write** | `SetAsync`, `IncrementAsync`, `UpdateAsync` | `300 + concurrentUsers × 20` |
| **List** | `GetSortedAsync` | `300 + concurrentUsers × 2` |
| **Remove** | `RemoveAsync` | `300 + concurrentUsers × 40` |

> `UpdateAsync` counts against **both** read and write budgets.

### Server-Level Limits (Configurable, Checked 2026-11-26)

Individual servers enforce configurable per-server caps alongside the experience-level limits above (official [Server Limits](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits#server-limits), checked 2026-11-26). Use `DataStoreService:SetRateLimitForRequestType()` and `DataStoreService:GetRequestBudgetForRequestType()` to configure or inspect each server's budget. The default per-server budgets below apply if `SetRateLimitForRequestType()` is not called:

#### Default Server Limits — Standard DataStores

| Request Type | `DataStoreRequestType` | Requests per Minute |
|---|---|---|
| **Read** | `StandardRead` | `60 + numPlayers × 40` |
| **Write** | `StandardWrite` | `60 + numPlayers × 40` |
| **List** | `StandardList` | `5 + numPlayers × 2` |
| **Remove** | `StandardRemove` | `60 + numPlayers × 40` |

#### Default Server Limits — Ordered DataStores

| Request Type | `DataStoreRequestType` | Requests per Minute |
|---|---|---|
| **Read** | `OrderedRead` | `60 + numPlayers × 40` |
| **Write** | `OrderedWrite` | `30 + numPlayers × 5` |
| **List** | `OrderedList` | `5 + numPlayers × 2` |
| **Remove** | `OrderedRemove` | `30 + numPlayers × 5` |

### Per-Key Throughput Limits

| Direction | Limit |
|---|---|
| Read | 25 MB per minute per key |
| Write | 4 MB per minute per key |

### Data Size Limits

| Component | Max Characters |
|---|---|
| Data store name | 50 |
| Key name | 50 |
| Scope | 50 |
| Key value (data) | 4,194,304 (4 MB) |

Queue limit: 30 requests per queue. When full, requests are dropped (error 301–306).

---

## OrderedDataStore

`OrderedDataStore` stores **integer values only** and supports sorted queries.
Ideal for leaderboards, high-score tables, and ranking systems.

```luau
--!strict
local DataStoreService = game:GetService("DataStoreService")
local leaderboardStore = DataStoreService:GetOrderedDataStore("TopScores")

-- Write a score
local success, err = pcall(function()
    leaderboardStore:SetAsync("Player_5678", 9500)
end)

-- Read top 10 (descending order)
local success, pages = pcall(function()
    return leaderboardStore:GetSortedAsync(false, 10)
end)
if success then
    local entries = pages:GetCurrentPage()
    for rank, entry in entries do
        print(`#{rank}: {entry.key} — {entry.value}`)
    end
end
```

> **Note:** OrderedDataStore does NOT support versioning or metadata.
> `DataStoreKeyInfo` is always `nil` for ordered data store keys.

## 7. MemoryStoreService

Temporary, low-latency data storage for cross-server coordination. Data is **not persisted**
across server restarts — all entries have a TTL (Time-To-Live).

### Data Structures

| Structure | Key Limit | Value Limit | Use Case |
|-----------|-----------|-------------|----------|
| `SortedMap` | 128 chars (sort key 128 chars) | 32 KB | Leaderboards, matchmaking queues |
| `Queue` | — | 32 KB per item (measured: not stated on the official page) | Job queues, event pipelines |
| `HashMap` | 128 chars | 32 KB | Session state, cross-server cache |

A single sorted map or queue holds at most 1,000,000 items and 100 MB. Measured in Studio 0.742:
a 32 KB value or queue item was accepted, 33 KB failed with `ItemValueSizeTooLarge`.

### Quotas (official *Memory stores* page)

| Quota | Value |
|-------|-------|
| Requests | `1000 + 120 × [concurrent users]` **request units** per minute, shared by all calls in the game (most calls cost 1 unit) |
| Memory | `64 KB + 1.2 KB × [number of users]` for the whole game; a playtest reported a quota of 65,536 bytes |
| Expiration | 0 to 3,888,000 seconds (45 days, also the default); outside that range: `InvalidExpirationTime` |
| Hash map key | about 5,000 write and 15,000 read units per minute per item key, on top of the per-partition limits |

### Usage Example
```lua
--!strict
local MemoryStoreService = game:GetService("MemoryStoreService")

local leaderboard = MemoryStoreService:GetSortedMap("GlobalLeaderboard")

-- Write with 1-hour TTL
local success, err = pcall(function()
    leaderboard:SetAsync("player_123", 1500, 3600)
end)

-- Read top 10
local success, items = pcall(function()
    return leaderboard:GetRangeAsync(Enum.SortDirection.Descending, 10)
end)
```

> **Caution:** MemoryStoreService is for **temporary** data only. It is not a
> replacement for DataStoreService. Data loss is expected on server restarts.

---

## Versioning

SetAsync, UpdateAsync, and IncrementAsync create **versioned backups** using the
first write to each key in each UTC hour. Successive writes in the same hour
overwrite the previous data. Versioned backups expire **30 days** after a new
write overwrites them. The latest version never expires.

### Key Functions

| Function | Purpose |
|---|---|
| `ListVersionsAsync(key, sortDir, minDate?, maxDate?)` | List all versions for a key |
| `GetVersionAsync(key, version)` | Retrieve a specific version |
| `RemoveVersionAsync(key, version)` | Delete a specific version |

```luau
--!strict
-- Revert a key to state before a specific timestamp
local DataStoreService = game:GetService("DataStoreService")
local store = DataStoreService:GetDataStore("PlayerData")

local KEY = "User_1234"
local maxDate = DateTime.fromUniversalTime(2026, 06, 20, 12, 00)

local listOk, pages = pcall(function()
    return store:ListVersionsAsync(KEY, Enum.SortDirection.Descending, nil, maxDate.UnixTimestampMillis)
end)
if listOk then
    local items = pages:GetCurrentPage()
    if #items > 0 then
        local closest = items[1]
        local getOk, value, info = pcall(function()
            return store:GetVersionAsync(KEY, closest.Version)
        end)
        if getOk and info then
            -- Restore only when no active server session holds KEY, or that session's next save
            -- will overwrite the restore. Pass info:GetUserIds() so GDPR user IDs are not cleared.
            local setOptions = Instance.new("DataStoreSetOptions")
            setOptions:SetMetadata(info:GetMetadata())
            local setOk, setErr = pcall(function()
                store:SetAsync(KEY, value, info:GetUserIds(), setOptions)
            end)
            if not setOk then
                warn(`[DataStore] Failed to restore {KEY}: {setErr}`)
            end
        end
    end
end
```

---

## Storage & Access Limits (Updated April 2026)

Data stores are subject to both **experience-level and server-level limits** (checked 2026-11-26 against the official [Error Codes & Limits](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits) page).

### Storage Limit Formula
```
Total latest version storage limit = 500 MB + 1 MB × lifetime user count
```

- A **lifetime user** is any user who has joined the experience at least once
- Deleted/replaced keys (accessible through version APIs) do NOT count
- Data stores deleted via Open Cloud `DeleteDataStore` continue counting for 30 days

### Overage Handling
If storage exceeds the limit, Roblox handles overages **without immediate write failures**:
- Overages are charged via **Robux deductions** or covered by **Extended Services** subscription
- No data loss — writes continue working during overage

### Notification Thresholds
Automated notifications are sent at:
| Threshold | Action |
|-----------|--------|
| **60%** | Info notification |
| **80%** | Warning notification |
| **90%** | Critical warning |
| **100%** | Overage begins, Robux billing starts |

### Monitoring Dashboard
Monitor storage usage via **Creator Hub → Data Stores Manager**:
- Real-time storage consumption per DataStore
- Access rate monitoring
- Overage billing visibility

> [!TIP]
> Enable the **Extended Services** free monthly tier for additional capacity
> without per-overage charges. Opt in via Creator Hub → Subscriptions.

---

## ProfileStore (Community Framework)

[ProfileStore](https://madstudioroblox.github.io/ProfileStore/) by loleris is the
**successor to ProfileService** and the recommended community framework for
player data management. It wraps `DataStoreService` with critical safeguards.

### Session Locking
- Only **one server** can "own" a player's data at a time
- Prevents data corruption and item duplication exploits
- Handles server-to-server handover gracefully during teleports

### Auto-Save
- Automatically saves data at regular intervals (default: **300 seconds**)
- Dramatically reduces DataStore API calls vs manual approaches
- Saves on `PlayerRemoving` and `game:BindToClose`

### Data Migration
- Supports schema versioning via `Profile.Data` reconciliation
- Define a template and ProfileStore fills in missing fields automatically

### Basic Usage Pattern
```luau
--!strict
--@skilltest: requires ProfileStore
-- ServerScriptService/PlayerDataManager.server.luau
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local ProfileStore = require(ServerStorage:WaitForChild("ProfileStore") :: ModuleScript)

local DATA_TEMPLATE = {
    coins = 0,
    gems = 0,
    inventory = {},
    settings = { musicVolume = 0.5 },
    dataVersion = 1,
}

local playerStore = ProfileStore.New("PlayerData", DATA_TEMPLATE)
local profiles: { [Player]: typeof(playerStore:StartSessionAsync()) } = {}

local function onPlayerAdded(player: Player)
    local profile = playerStore:StartSessionAsync(`Player_{player.UserId}`, {
        Cancel = function()
            return player.Parent ~= Players
        end,
    })
    if profile == nil then
        player:Kick("Unable to load data. Please rejoin.")
        return
    end
    profile:AddUserId(player.UserId)
    profile:Reconcile() -- fill missing template fields
    profile.OnSessionEnd:Connect(function()
        profiles[player] = nil
        player:Kick("Session ended.")
    end)
    if player.Parent == Players then
        profiles[player] = profile
    else
        profile:EndSession()
    end
end

local function onPlayerRemoving(player: Player)
    local profile = profiles[player]
    if profile then
        profile:EndSession()
    end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
```

---

## Data Schema Best Practices

1. **Single key per player** — store all data in one table keyed by `Player_{UserId}`
2. **Use a template** — define defaults so new fields auto-populate
3. **Include a version number** — `dataVersion = 1` enables future migrations
4. **Flatten when possible** — deeply nested tables are harder to migrate
5. **Never store Instances** — only serializable Luau types (string, number, boolean, table, buffer)
6. **Use `UpdateAsync` for player data** — atomic, prevents overwrites
7. **Bind to close** — for raw DataStore saves, wait for all spawned save tasks to finish inside `game:BindToClose` (Roblox waits up to 30 seconds for bound functions to complete; ProfileStore handles its own shutdown saves)

<!-- skilltest: prelude save-on-leave -->
```luau
--!strict
-- Track every final save (from PlayerRemoving or shutdown) in one registry so
-- BindToClose waits for saves already in flight and starts each final save once.
local SHUTDOWN_SAVE_BUDGET_SECONDS = 28
local finalSaveState: { [Player]: "saving" | "saved" } = {}
local inFlightSaves = 0

local function saveFinalOnce(player: Player)
    if finalSaveState[player] ~= nil then
        return
    end
    finalSaveState[player] = "saving"
    inFlightSaves += 1

    local ok, err = pcall(onPlayerRemoving, player)
    if not ok then
        warn(`[DataService] Final save failed for {player.UserId}: {err}`)
    end

    finalSaveState[player] = if player:IsDescendantOf(Players) then "saved" else nil
    inFlightSaves -= 1
end

Players.PlayerRemoving:Connect(function(player: Player)
    saveFinalOnce(player)
    if finalSaveState[player] == "saved" then
        finalSaveState[player] = nil
    end
end)

game:BindToClose(function()
    -- Wait for saves already started by PlayerRemoving and start one for remaining players.
    -- Roblox waits up to 30s for bound functions to complete.
    local deadline = os.clock() + SHUTDOWN_SAVE_BUDGET_SECONDS
    for _, player in Players:GetPlayers() do
        if finalSaveState[player] == nil then
            task.spawn(saveFinalOnce, player)
        end
    end

    while inFlightSaves > 0 and os.clock() < deadline do
        task.wait()
    end

    if inFlightSaves > 0 then
        warn(`[DataService] Shutdown deadline reached with {inFlightSaves} final saves still in flight`)
    end
end)
```

---

## LEGACY

### DataStore2 (Kampfkarren; its default saving method is the "berezaa method")
**Status:** Outdated. Not recommended for new projects.

DataStore2 was an early community wrapper that introduced:
- Ordered backups across multiple DataStore keys
- Automatic retry logic
- Caching layer

**Why to move off it** (it is a community module; "deprecated" here is this skill's advice, not a
Roblox status):
- Its `OrderedBackups` saving method writes a new key on every save (many DataStore keys)
- No session locking in its source — vulnerable to data duplication across servers
- Last commit to its repository: June 2023; it does not use DataStore versioning or metadata
- Roblox's native versioning now covers the backup use case

### Migration: DataStore2 → ProfileStore

1. Start the ProfileStore session, but block gameplay (do not expose the profile to game systems) until migration completes
2. Call `oldStore:SetBackup(3)` to bound DataStore2's internal retries (without `SetBackup`, DataStore2 retries failed reads indefinitely), then read via `oldStore:Get(nil)` inside `pcall` and verify `not oldStore:IsBackup()`
3. Treat only `nil` (with `not oldStore:IsBackup()`) as a verified absent record. If `oldData ~= nil`, validate that it is a table with valid expected fields before modifying `profile.Data`; reject unrecognized scalars or malformed fields so legacy data is never skipped permanently
4. Set `profile.Data.migrated = true` only after copying validated data or confirming absence (`oldData == nil` with `not oldStore:IsBackup()`). If the read errors, returns a backup, or returns an unrecognized value, end the session and kick the player without setting `migrated = true`

<!-- skilltest: requires DataStore2; expect datastore2-migrates -->
```luau
--!strict
-- Run this BEFORE exposing `profile` to game systems so the player cannot play with unmigrated data.
-- Returns true only when migration succeeded or the legacy record was verified absent.
local LEGACY_READ_RETRIES = 3

local function isFiniteNumber(value: any): boolean
    return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function migrateFromDataStore2(player: Player, profile: any): boolean
    if profile.Data.migrated then
        return true
    end

    local DataStore2 = require(game:GetService("ServerStorage"):WaitForChild("DataStore2") :: ModuleScript) -- legacy module
    local oldStore = DataStore2("PlayerSave", player)
    -- Bound DataStore2 retries so failed reads do not stall join while ProfileStore holds a session.
    oldStore:SetBackup(LEGACY_READ_RETRIES)

    local ok, oldData = pcall(function()
        return oldStore:Get(nil)
    end)
    if not ok then
        warn(`[DataStore2Migration] Read failed for {player.UserId}: {oldData}`)
        return false
    end
    if oldStore:IsBackup() then
        warn(`[DataStore2Migration] Backup returned for {player.UserId}; refusing to migrate`)
        return false
    end

    if oldData == nil then
        -- Verified absent legacy key (not a backup): avoid repeat DataStore2 reads on future joins.
        profile.Data.migrated = true
        return true
    end

    if typeof(oldData) ~= "table" then
        warn(`[DataStore2Migration] Unrecognized legacy value type ({typeof(oldData)}) for {player.UserId}`)
        return false
    end
    if oldData.coins ~= nil and not isFiniteNumber(oldData.coins) then
        warn(`[DataStore2Migration] Invalid legacy coins field for {player.UserId}`)
        return false
    end
    if oldData.inventory ~= nil and typeof(oldData.inventory) ~= "table" then
        warn(`[DataStore2Migration] Invalid legacy inventory field for {player.UserId}`)
        return false
    end

    if oldData.coins ~= nil then
        profile.Data.coins = oldData.coins
    end
    if oldData.inventory ~= nil then
        profile.Data.inventory = table.clone(oldData.inventory)
    end
    profile.Data.migrated = true
    return true
end
```

### ProfileService → ProfileStore Changes

ProfileStore is the direct successor by the same author (loleris). Key changes:

| Aspect | ProfileService (Old) | ProfileStore (New) |
|---|---|---|
| **Load method** | `ProfileStore:LoadProfileAsync()` | `ProfileStore:StartSessionAsync()` |
| **Release method** | `Profile:Release()` | `Profile:EndSession()` |
| **Auto-save interval** | 30 seconds | 300 seconds (configurable) |
| **API style** | Callback-heavy | Promise/session-based |
| **Reconcile** | `Profile:Reconcile()` | `Profile:Reconcile()` (same) |
| **Module name** | `ProfileService` | `ProfileStore` |

Migration is straightforward: ProfileStore reads the same underlying DataStore
keys. Update method names and adjust auto-save expectations.
