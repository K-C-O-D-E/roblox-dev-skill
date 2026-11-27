# Worked Examples — end-to-end patterns for an agent

> Every other reference in this skill answers *"what is true about Roblox?"*. This one answers
> *"what do I actually do, in order, and how do I know it worked?"*

Each example carries four things, and the middle two exist to stop an agent pattern-matching a
sample onto a task it does not fit:

| Section | Purpose |
|---|---|
| **Trigger** | When this example applies |
| **Not this** | Requests that look similar and route elsewhere — read this before matching |
| **Sequence** | The real calls, with real signatures |
| **Verification** | How you know it worked. A sample that stops at "code written" is not done |

**Two rules that apply to every example below.**

1. **Do not stop at generated code.** Every example ends in a verification step. If MCP is not
   connected, hand the user the verification steps instead of skipping them.
2. **Read the routing table in `SKILL.md` first.** These examples show sequence, not facts. Where an
   example and a reference file disagree, the reference file wins.

## Table of Contents

1. [Add a server-authoritative feature](#1-add-a-server-authoritative-feature)
2. [Debug a runtime error through MCP](#2-debug-a-runtime-error-through-mcp)
3. [Migrate a deprecated API](#3-migrate-a-deprecated-api)
4. [Look up an API you are not certain about](#4-look-up-an-api-you-are-not-certain-about)
5. [Refuse and redirect a request that breaks the trust boundary](#5-refuse-and-redirect-a-request-that-breaks-the-trust-boundary)
6. [Grant a developer product purchase](#6-grant-a-developer-product-purchase)
7. [Change the shape of saved player data](#7-change-the-shape-of-saved-player-data)
8. [Open a menu from an Input Action](#8-open-a-menu-from-an-input-action)
9. [Concept Image to 3D Asset, Physics Contraption, and Playtest](#9-concept-image-to-3d-asset-physics-contraption-and-playtest)
10. [Auto-Route to Built-in Studio Skills and Verify Stale Steps](#10-auto-route-to-built-in-studio-skills-and-verify-stale-steps)
11. [Anti-patterns these examples exist to prevent](#anti-patterns-these-examples-exist-to-prevent)

---

## 1. Add a server-authoritative feature

**Trigger:** "add coins / XP / an inventory / a shop", "let the player buy X", "reward the player
for Y" — anything where the client must *cause* a change to persistent or shared state.

**Not this:**
- Purely cosmetic client feedback (a sound, a particle, a tween on the local player's UI) — no
  server round-trip is needed; over-engineering it is its own failure. → `ui-systems.md`
- Robux purchases → `monetization.md`, not a custom RemoteEvent
- Saving the result → `datastore-persistence.md` for session locking, which this example omits

**Routing:** `networking.md` + `security-hardening.md`, then `datastore-persistence.md` if it
persists.

**Sequence:**

1. **Decide where authority lives before writing anything.** The client sends *intent*, never
   outcome. `CollectCoin(coinId)` is intent; `AddCoins(50)` is an outcome and is exploitable by
   definition. If the request is phrased as the latter, re-shape it and say why.
2. Write the server handler with **every** validation layer from `security-hardening.md` §2–3 —
   type, NaN/inf, range, ownership, state, and rate limit. They are not optional and not
   independent: a range check alone is defeated by NaN.
3. Write the client caller last. It is the untrusted half; it holds no rules.

```luau
--!strict
-- ServerScriptService/CoinService.server.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local collectRemote = ReplicatedStorage:WaitForChild("CollectCoin") :: RemoteEvent
local coinFolder = workspace:WaitForChild("Coins")

local COOLDOWN_SECONDS = 0.25
local MAX_REACH_STUDS = 12

local lastCollect: { [Player]: number } = {}
local coinValues: { [Player]: number } = {}

local function isFiniteNumber(value: unknown): boolean
	if typeof(value) ~= "number" then
		return false
	end
	local n = value :: number
	return n == n and math.abs(n) ~= math.huge -- rejects NaN and ±inf
end

collectRemote.OnServerEvent:Connect(function(player: Player, coin: unknown)
	-- 1. rate limit, before any work
	local now = os.clock()
	if now - (lastCollect[player] or 0) < COOLDOWN_SECONDS then
		return
	end
	lastCollect[player] = now

	-- 2. the argument is an Instance, and one we actually own
	if typeof(coin) ~= "Instance" then
		return
	end
	local part = coin :: Instance
	if not part:IsDescendantOf(coinFolder) or not part:IsA("BasePart") then
		return
	end

	-- 3. the player is actually near it — never trust a client-reported position
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local distance = (root.Position - (part :: BasePart).Position).Magnitude
	if not isFiniteNumber(distance) or distance > MAX_REACH_STUDS then
		return
	end

	-- 4. state validation: claim the coin exactly once
	if part:GetAttribute("Claimed") == true then
		return
	end
	part:SetAttribute("Claimed", true)

	coinValues[player] = (coinValues[player] or 0) + 1
	part:Destroy()
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastCollect[player] = nil
	coinValues[player] = nil -- persist before clearing in real code; see datastore-persistence.md
end)
```

**Verification:**

```text
1. get_studio_state                      → confirm Edit is available
2. multi_edit                            → write the script (Edit datamodel, one script per call)
3. get_console_output                    → catch load/syntax errors BEFORE playing
4. start_stop_play                       → begin playtest
5. execute_luau (datamodel_type: Client) → FireServer the remote with junk
6. execute_luau (datamodel_type: Server) → assert every coin still exists, unclaimed
7. execute_luau (Client), then (Server)  → one valid claim: that coin is gone, the others remain
8. get_console_output                    → no errors from CoinService
9. start_stop_play                       → stop
```

Step 5 is the one agents skip. Proving the happy path works is half a test; the handler exists to
reject the unhappy path. Fire it **from the Client datamodel**: a server cannot raise its own
`OnServerEvent`, so junk "fired" from a Server `execute_luau` tests nothing. Send `0/0` (NaN), a
string, `nil`, a table, a `Part` from outside `coinFolder`, and 50 calls in a loop at a coin out of
reach. Assert on what the server can see: `coinValues` is a local, so check that no coin was
destroyed or marked `Claimed`, then that one valid claim does remove its coin. (Run exactly this way
in Studio 0.742, 2026-10-11: all junk rejected, the valid claim accepted, a second claim of the same
coin rejected, no errors.)

---

## 2. Debug a runtime error through MCP

**Trigger:** "this errors", "it stopped working", a pasted stack trace.

**Not this:**
- "This is slow" → `performance-optimization.md`; a profiling problem, not a debugging one
- "Type checking complains" → `luau-fundamentals.md`; static, no playtest needed. After a Studio
  update, check whether Luau 0.739's stricter in-body generic checking is the cause
- "It works in Studio but not in the live game" → suspect `StreamingEnabled` or a client/server
  assumption, not a syntax bug

**Routing:** `mcp-integration.md` for signatures, `agent-safety.md` before the first write. For
breakpoints, thread stacks, and variable inspection beyond `print()` debugging, call
`get_roblox_skill("rbx-debug")` first (`ScriptDebuggerService` is `PluginSecurity`, so it runs via
`execute_luau`, not game scripts).

**Sequence:**

```text
1. list_roblox_studios   → resolve studio_id, and say out loud which place it is
2. get_console_output    → read the actual error and stack trace, do not guess from the description
3. get_roblox_skill      → load "rbx-debug" if breakpoints / stack inspection are needed
4. script_read           → read the offending script; line numbers here are real
5. execute_luau          → inspect live state (datamodel_type: Server or Client)
6. start_stop_play       → STOP the playtest — multi_edit cannot write during one
7. multi_edit            → apply the fix (datamodel_type: Edit only)
8. start_stop_play       → restart
9. get_console_output    → confirm the error is gone AND no new warnings appeared
```

**Failure modes, with the real cause:**

| What you see | Cause |
|---|---|
| `multi_edit` fails during a playtest | Its `datamodel_type` enum is `Edit` only. Step 5 is mandatory |
| `multi_edit` fails with no match | `old_string` must match **exactly**, whitespace included. You skipped `script_read` |
| The fix lands in the wrong place | A stale `studio_id`. Nothing warns you |
| `script_grep` line numbers do not match | Known defect. Use it to find *which* script, then `script_read` for *where* |

**Verification:** step 8 is not "no error". It is *no error and no new warning* — a deprecation
notice introduced by your fix is a future break.

---

## 3. Migrate a deprecated API

**Trigger:** "modernize this", "remove deprecated calls", a deprecation warning in the console.

**Not this:**
- A wholesale rewrite. `legacy-migration.md` has a "When NOT to Migrate" section for a reason:
  working code with no deprecation warning is not a migration target
- `UserInputService` → IAS. Neither `UserInputService` nor `ContextActionService` is deprecated
  (0.745 dump); moving is a design choice, not a fix. The `ContextActionService` page does say its
  binding methods are "planned for deprecation" (2026-10-22), so new bindings belong in IAS

**Routing:** `legacy-migration.md`, plus the local dump for the authoritative status.

**Sequence:**

1. **Confirm the deprecation locally instead of trusting memory:**

   ```bash
   jq '.Members[] | select(.Name=="<MemberName>") | {Name, Tags, Security}' \
     ~/RobloxDocs/RobloxAPI/classes/<ClassName>.json
   ```

   A `Deprecated` tag often carries a `PreferredDescriptorName` naming the replacement — that is
   the authoritative answer, not a guess.
2. `script_grep("<oldName>")` to find which scripts are affected. Capped at 50 matches; confirm
   its line numbers with `script_read` (once seen 15 lines off).
3. `script_read` each hit. **Check whether the replacement yields**: `GetTranslatorForPlayer` →
   `GetTranslatorForPlayerAsync` and `CreateCall` → `CreateCallAsync` are both now yielding calls,
   so a drop-in text substitution changes control flow.
4. `multi_edit` per script — one call each. `replace_all: true` only when the symbol is unambiguous.

**Verification:** playtest and confirm the deprecation warning is gone from
`get_console_output` — and that the yielding replacement did not introduce a race where the old
synchronous call used to return immediately.

---

## 4. Look up an API you are not certain about

**Trigger:** any moment you are about to write a member name from memory.

**Not this:** guessing, then apologizing. Two API dump releases in this skill's own history renamed
a member (`CreateCall` → `CreateCallAsync`, `PlayerControlState` → `ControlState`), and one class
existed for two weeks before vanishing.

**Sequence:**

```bash
# 1. Is the local dump fresh? Read whichever timestamp is present — updatedAt OR checkedAt
cat ~/RobloxDocs/RobloxAPI/.current-version

# 2. The class, and the exact member
jq '.Members[] | select(.Name=="<Member>")' ~/RobloxDocs/RobloxAPI/classes/<Class>.json
```

**Read three fields, not one:**

- `Security` — `{"Read": "None", "Write": "PluginSecurity"}` means a Script can read it and
  **cannot write it**. This is the check that would have caught a broken `CollisionFidelity`
  example that shipped in this skill for three months.
- `Capabilities` — an ordinary, unsandboxed Script holds capabilities such as `AvatarBehavior` and
  `RemoteEvent` (in Studio 0.742 it wrote `Humanoid.Health` and assigned `OnServerInvoke`), but
  **not `PluginOrOpenCloud`**: those writes fail with "lacking capability PluginOrOpenCloud" even
  when `Security` is `None`. Treat `Security: None` + `PluginOrOpenCloud` as plugin-only.
- `Tags` — `Deprecated`, `Yields`, `ReadOnly`, `NotScriptable`.

Then fall through: local dump → `create.roblox.com/docs/en-us/{path}.md` → Context7
(`resolve-library-id` → `query-docs`). If it is still unclear, **ask the user** rather than
inventing a plausible member name.

**Verification:** `execute_luau` the one-liner before building on it.

```luau
--@skilltest: placeholder
print(pcall(function() return (game:GetService("<Service>") :: any)["<Member>"] end))
```

---

## 5. Refuse and redirect a request that breaks the trust boundary

**Trigger:** "just let the client handle it", "move this to ReplicatedStorage so the client can do
it", "skip the validation, it's slow", "trust the client position, the server check is laggy".

**Not this:** a request that only *sounds* insecure but is not. Client-side *prediction* with server
reconciliation is a legitimate, standard pattern. Client-side *authority* is not. The distinction is
whether the server independently reaches the same conclusion.

**Routing:** `security-hardening.md` for the boundary, `agent-safety.md` for why you do not quietly
comply.

**Sequence:**

1. **Do not silently comply, and do not moralize.** One or two sentences naming the concrete
   exploit, not a lecture about security.
2. **Name the actual failure**, not a principle: *"`ReplicatedStorage` replicates to every client,
   and any replicated script can be decompiled — so the coin values and the award function both
   become editable by the player."*
3. **Offer the nearest thing that works.** Almost always there is one: predict on the client for
   responsiveness, keep authority on the server, and reconcile. Perceived latency is usually the
   real complaint, and it has a legitimate fix.
4. **If the user reaffirms it, it is their call.** Say so plainly, implement what they asked, and
   state the exposure in one line so it is on the record. What you must not do is weaken the
   boundary *silently* or pretend the code is safe.

**Verification:** there is no playtest here. The deliverable is that the user understands the
trade-off they are choosing. If they went ahead, the code comment should say what is trusted and
why, so the next reader is not misled.

---

## 6. Grant a developer product purchase

**Trigger:** "sell coins / a potion / a boost for Robux", "my ProcessReceipt", "players paid but got
nothing", "players got the item twice".

**Not this:**
- A **game pass** (bought once, owned forever): check `UserOwnsGamePassAsync`, no receipt involved →
  `monetization.md`
- Player-to-player Robux → the Transfers API in `monetization.md`
- An in-game currency purchase that costs no Robux → example 1 (a server-validated remote)

This example uses `ProcessReceipt`. The official reference now presents
`MarketplaceService:BindReceiptHandler` as the alternative (see `monetization.md`); the
`PurchaseId` rule below applies to both.

**Routing:** `monetization.md` + `datastore-persistence.md`.

**Sequence:**

1. **One script owns `ProcessReceipt`.** Setting it from a second script silently replaces the
   first.
2. **A handler mutates only the serializable player record, with no side effects.** `GlobalDataStore:UpdateAsync()` can invoke its transform function more than once when another server writes the same key, discarding the earlier call's return value. Never mutate `leaderstats` or grant in-memory items inside the transform function, or a retry can grant twice.
3. **Make it idempotent and durable through the single session writer.** `ProcessReceipt` runs again for every *unresolved* purchase each time the player joins, and a purchase counts as resolved only once `PurchaseGranted` is returned **and** recorded on Roblox's side. Store the granted value **and** the `PurchaseId` together in the **same authoritative player record and writer** that owns earned coins, spending, and session saves (`PlayerData_v1` below, serialized with session saves via `UpdateAsync`, or in a session-locked ProfileStore record saved before returning `PurchaseGranted`). Preserve all unrelated fields, keep unsaved gameplay earnings intact, and mirror the updated session balance into `leaderstats`. Never write out-of-band to a player's key while a separate session writer holds an in-memory copy, or the next session save will overwrite the grant and `ProcessedReceipts`. Never evict old receipt IDs to make room for new ones: if a record reaches its storage cap, cancel the write (`NotProcessedYet`) until receipt history is archived or migrated safely.
4. **Return `NotProcessedYet` whenever you are unsure.** The purchase stays unresolved and is retried when the player next joins; it is never refunded or dropped by that answer.

```luau
--!strict
--@skilltest: provides ReceiptHandler
-- ModuleScript "ReceiptHandler" in ServerScriptService
-- Owns the player's authoritative session record and serializes receipt grants with session saves
-- so a later autosave or leave save never overwrites a paid grant or its ProcessedReceipts.
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local playerStore: DataStore = DataStoreService:GetDataStore("PlayerData_v1")
local MAX_STORED_RECEIPTS = 500

export type PlayerRecord = {
	Coins: number,
	ProcessedReceipts: { string },
	[string]: any,
}

local ReceiptHandler = {}

-- productId -> pure transform on a player record.
-- Return true ONLY when the grant was applied to `record`.
-- Runs inside UpdateAsync (and once on the live session after commit):
-- must NOT yield and must NOT mutate Instances or external state.
ReceiptHandler.handlers = {} :: { [number]: (record: PlayerRecord) -> boolean }

local sessions: { [Player]: PlayerRecord } = {}
local writingPlayers: { [Player]: boolean } = {}

-- Optional seam for isolated tests (never swap stores in production gameplay).
function ReceiptHandler.setDataStore(store: DataStore)
	playerStore = store
end

local function isValidId(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and math.floor(value) == value
end

local function hasReceipt(receipts: { string }, purchaseId: string): boolean
	for _, id in receipts do
		if id == purchaseId then
			return true
		end
	end
	return false
end

local function cloneRecord(oldData: any): PlayerRecord?
	if oldData == nil then
		return { Coins = 0, ProcessedReceipts = {} }
	end
	if typeof(oldData) ~= "table" then
		return nil -- reject corrupt non-table data rather than wiping it
	end

	local copy: { [string]: any } = table.clone(oldData)

	local rawCoins = copy.Coins
	if rawCoins == nil then
		copy.Coins = 0
	elseif typeof(rawCoins) ~= "number" or rawCoins ~= rawCoins or rawCoins == math.huge or rawCoins == -math.huge then
		return nil -- reject corrupt coin balance
	end

	local rawReceipts = copy.ProcessedReceipts
	local receipts: { string } = {}
	if rawReceipts ~= nil then
		if typeof(rawReceipts) ~= "table" then
			return nil -- reject corrupt receipt history
		end
		local count = 0
		for key, id in rawReceipts do
			if typeof(key) ~= "number" or key < 1 or math.floor(key) ~= key or typeof(id) ~= "string" or id == "" then
				return nil
			end
			count += 1
		end
		if count ~= #rawReceipts then
			return nil -- reject sparse or malformed array
		end
		for index = 1, count do
			receipts[index] = rawReceipts[index]
		end
	end

	copy.ProcessedReceipts = receipts
	return copy :: PlayerRecord
end

local function mergeReceipts(target: { string }, source: { string })
	for _, id in source do
		if not hasReceipt(target, id) then
			table.insert(target, id)
		end
	end
end

local function syncLeaderstats(player: Player, record: PlayerRecord)
	local leaderstats = player:FindFirstChild("leaderstats")
	local coins = leaderstats and leaderstats:FindFirstChild("Coins")
	if coins and coins:IsA("IntValue") then
		coins.Value = record.Coins
	end
end

local function acquireWriteLock(player: Player)
	while writingPlayers[player] do
		task.wait()
	end
	writingPlayers[player] = true
end

function ReceiptHandler.loadSession(player: Player): boolean
	local playerKey = `Player_{player.UserId}`
	local ok, rawData = pcall(function()
		return playerStore:GetAsync(playerKey)
	end)
	if not ok then
		warn(`[ReceiptHandler] Failed to load session for {player.UserId}: {rawData}`)
		return false
	end
	if not player:IsDescendantOf(Players) then
		return false -- player left while GetAsync yielded
	end
	local record = cloneRecord(rawData)
	if not record then
		warn(`[ReceiptHandler] Corrupt saved record for {player.UserId}`)
		return false
	end
	sessions[player] = record
	syncLeaderstats(player, record)
	return true
end

function ReceiptHandler.addCoins(player: Player, delta: number): boolean
	local session = sessions[player]
	if not session or typeof(delta) ~= "number" or delta ~= delta or delta == math.huge or delta == -math.huge then
		return false
	end
	session.Coins += delta
	syncLeaderstats(player, session)
	return true
end

function ReceiptHandler.saveSession(player: Player, unload: boolean?): boolean
	if not sessions[player] then
		return false
	end

	acquireWriteLock(player)
	if not sessions[player] then
		writingPlayers[player] = nil
		return false
	end
	local playerKey = `Player_{player.UserId}`
	local ok, err = pcall(function()
		playerStore:UpdateAsync(playerKey, function(oldData: any, keyInfo: DataStoreKeyInfo?)
			local stored = cloneRecord(oldData)
			if not stored then
				return nil -- do not overwrite corrupt data
			end
			local live = sessions[player]
			if not live then
				return nil
			end
			local candidate = cloneRecord(live)
			if not candidate then
				return nil
			end
			-- Preserve any receipts already committed in the store alongside live session state.
			mergeReceipts(candidate.ProcessedReceipts, stored.ProcessedReceipts)
			local userIds = if keyInfo then keyInfo:GetUserIds() else {}
			if #userIds == 0 and player.UserId > 0 then
				userIds = { player.UserId }
			end
			local metadata = if keyInfo then keyInfo:GetMetadata() else {}
			return candidate, userIds, metadata
		end)
	end)
	if unload then
		sessions[player] = nil
	end
	writingPlayers[player] = nil

	if not ok then
		warn(`[ReceiptHandler] Session save failed for {player.UserId}: {err}`)
		return false
	end
	return true
end

function ReceiptHandler.process(receiptInfo: { [string]: any }): Enum.ProductPurchaseDecision
	if typeof(receiptInfo) ~= "table" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local playerId = receiptInfo.PlayerId
	local productId = receiptInfo.ProductId
	local purchaseId = receiptInfo.PurchaseId
	if not isValidId(playerId) or not isValidId(productId) or typeof(purchaseId) ~= "string" or purchaseId == "" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(playerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local session = sessions[player]
	local leaderstats = player:FindFirstChild("leaderstats")
	if not (session and leaderstats and leaderstats:FindFirstChild("Coins")) then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- player session not ready yet
	end

	local handler = ReceiptHandler.handlers[productId]
	if not handler then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Fast idempotent path if this session already committed the receipt.
	if hasReceipt(session.ProcessedReceipts, purchaseId) then
		syncLeaderstats(player, session)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	acquireWriteLock(player)
	local lockedSession = sessions[player]
	if not lockedSession then
		writingPlayers[player] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if hasReceipt(lockedSession.ProcessedReceipts, purchaseId) then
		syncLeaderstats(player, lockedSession)
		writingPlayers[player] = nil
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local playerKey = `Player_{playerId}`
	local alreadyGranted = false
	local deferReason: string? = nil
	local ok, committed = pcall(function()
		return playerStore:UpdateAsync(playerKey, function(oldData: any, keyInfo: DataStoreKeyInfo?)
			alreadyGranted = false
			deferReason = nil
			local stored = cloneRecord(oldData)
			if not stored then
				deferReason = "corrupt saved record"
				return nil -- corrupt record: cancel write so nothing is overwritten
			end
			if hasReceipt(stored.ProcessedReceipts, purchaseId) then
				alreadyGranted = true
				return nil -- already durably granted: cancel redundant write
			end

			local live = sessions[player]
			if not live then
				deferReason = "player session unloaded"
				return nil
			end
			local candidate = cloneRecord(live)
			if not candidate then
				deferReason = "invalid session record"
				return nil
			end
			mergeReceipts(candidate.ProcessedReceipts, stored.ProcessedReceipts)
			if #candidate.ProcessedReceipts >= MAX_STORED_RECEIPTS then
				-- Never evict old receipt IDs: Roblox can redeliver an older unresolved receipt.
				-- Defer new grants until receipt history is archived or migrated safely.
				deferReason = `receipt history cap ({MAX_STORED_RECEIPTS}) reached`
				return nil
			end
			if handler(candidate) ~= true then
				deferReason = "product handler returned false"
				return nil -- cancel the write: purchase stays unresolved and retries later
			end
			table.insert(candidate.ProcessedReceipts, purchaseId)

			local userIds = if keyInfo then keyInfo:GetUserIds() else {}
			if #userIds == 0 and playerId > 0 then
				userIds = { playerId }
			end
			local metadata = if keyInfo then keyInfo:GetMetadata() else {}
			return candidate, userIds, metadata
		end)
	end)

	local decision = Enum.ProductPurchaseDecision.NotProcessedYet
	if ok then
		local live = sessions[player]
		if alreadyGranted then
			if live then
				if not hasReceipt(live.ProcessedReceipts, purchaseId) then
					table.insert(live.ProcessedReceipts, purchaseId)
				end
				syncLeaderstats(player, live)
			end
			decision = Enum.ProductPurchaseDecision.PurchaseGranted
		elseif typeof(committed) == "table" and hasReceipt((committed :: PlayerRecord).ProcessedReceipts, purchaseId) then
			if live then
				-- Apply the committed grant once to the live session so unsaved gameplay earnings
				-- earned during the UpdateAsync yield and the next session save stay consistent.
				handler(live)
				if not hasReceipt(live.ProcessedReceipts, purchaseId) then
					table.insert(live.ProcessedReceipts, purchaseId)
				end
				syncLeaderstats(player, live)
			end
			decision = Enum.ProductPurchaseDecision.PurchaseGranted
		elseif deferReason then
			warn(`[ReceiptHandler] Deferred {purchaseId}: {deferReason}`)
		end
	else
		warn(`[ReceiptHandler] {purchaseId}: {committed}`)
	end

	writingPlayers[player] = nil
	return decision
end

return ReceiptHandler
```

<!-- skilltest: expect receipt-idempotent -->
```luau
--!strict
--@skilltest: requires ReceiptHandler
-- ServerScriptService/Receipts.server.luau: the ONLY script that sets ProcessReceipt
local MarketplaceService = game:GetService("MarketplaceService")
local ServerScriptService = game:GetService("ServerScriptService")

local ReceiptHandler = require(ServerScriptService:WaitForChild("ReceiptHandler") :: ModuleScript)

local COINS_100 = 111111111 -- your developer product ID

-- Pure record mutation only (no yields, no Instance side effects inside UpdateAsync).
ReceiptHandler.handlers[COINS_100] = function(record: { Coins: number, ProcessedReceipts: { string }, [string]: any }): boolean
	record.Coins += 100
	return true
end

MarketplaceService.ProcessReceipt = ReceiptHandler.process
```

**Verification:** test the logic directly; you do not need a real purchase. In a playtest,
`execute_luau` (Server) can `require` the module (it gets its own copy, so register a test handler
on that copy), point it at an isolated test store with `setDataStore`, seed an existing player
record (for example `Coins = 500`, `Gems = 7`), load the session, add unsaved gameplay coins
(`+25`), call `process` with fake receipts, and run `saveSession`:

| Call | Expected |
|---|---|
| Malformed receipt (`{}` or missing IDs) | `NotProcessedYet` |
| Session not loaded yet | `NotProcessedYet` |
| New `PurchaseId` with stored `Coins = 500`, `Gems = 7`, and `+25` unsaved earnings, then `saveSession` | `PurchaseGranted`, durable `Coins == 625`, `Gems == 7` preserved, `ProcessedReceipts` holds `PurchaseId` once after both grant and `saveSession` |
| The **same** `PurchaseId` again | `PurchaseGranted`, handler does **not** run again, stored `Coins` stays `625`, `ProcessedReceipts` count stays `1` |
| Handler returns `false` | `NotProcessedYet`, stored `Coins` stays `625` |
| Unknown `ProductId` | `NotProcessedYet` |
| `PlayerId` of someone not in the server | `NotProcessedYet` |

(Not yet re-run in Studio after the durable-record revision; static checks pass and `tools/skill-test/expect/receipt-idempotent.luau` covers all seven rows.) Use
`PurchaseId`s with a `test-` prefix so they cannot collide with real purchases.

---

## 7. Change the shape of saved player data

**Trigger:** "rename a saved field", "add a field to existing saves", "change how inventory is
stored", "old players lost their data after my update".

**Not this:**
- A brand-new game with no saved data yet: just change the default
- Moving from DataStore2 or ProfileService to ProfileStore → `datastore-persistence.md` /
  `legacy-migration.md`
- Wiping progress on purpose (a season reset): that is a product decision; say so, do not
  "migrate" it

**Routing:** `datastore-persistence.md`.

**Sequence:**

1. **Keep the DataStore name.** A new name is a new, empty store: every player starts over.
2. **Version the data and migrate on load.** Store a `version` field; data saved before versioning
   existed counts as version 1. Each migration step upgrades exactly one version.
3. **Never edit a migration that has shipped**; add the next step. Old saves still pass through it.
4. **Refuse data from the future.** During a rolling update an older server can load a save that a
   newer server already upgraded. It must not "fix" it down or save over it: reject the load.
5. **A failed read is not an empty save.** Never fall back to defaults when `GetAsync` errors, or
   the next save overwrites the player's real data (see `project-structure.md`, PlayerDataService).

<!-- skilltest: expect schema-migrates -->
```luau
--!strict
--@skilltest: provides PlayerDataSchema
-- ModuleScript "PlayerDataSchema" in ServerScriptService
export type PlayerData = {
	version: number,
	coins: number,
	gems: number,
	inventory: { [string]: number }, -- item name -> count
}

local CURRENT_VERSION = 3

-- migrations[n] upgrades a version-n table to version n + 1.
local migrations: { [number]: (data: { [string]: any }) -> () } = {
	[1] = function(data) -- v1 -> v2: the field "Coins" was renamed "coins"
		data.coins = data.Coins or 0
		data.Coins = nil
	end,
	[2] = function(data) -- v2 -> v3: inventory went from a list to a count map; gems added
		local counts: { [string]: number } = {}
		for _, item in data.inventory or {} do
			counts[item] = (counts[item] or 0) + 1
		end
		data.inventory = counts
		data.gems = data.gems or 0
	end,
}

local PlayerDataSchema = {}

function PlayerDataSchema.default(): PlayerData
	return { version = CURRENT_VERSION, coins = 0, gems = 0, inventory = {} }
end

-- Errors if the save is newer than this server understands.
function PlayerDataSchema.migrate(stored: { [string]: any }): PlayerData
	local data = table.clone(stored)
	local version = data.version or 1
	if version > CURRENT_VERSION then
		error(`save is version {version}; this server only knows up to {CURRENT_VERSION}`)
	end
	while version < CURRENT_VERSION do
		migrations[version](data)
		version += 1
	end
	data.version = CURRENT_VERSION
	return data :: any
end

return PlayerDataSchema
```

<!-- skilltest: expect load-new-player -->
```luau
--!strict
--@skilltest: requires PlayerDataSchema
-- Inside your load function (server)
local DataStoreService = game:GetService("DataStoreService")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerDataSchema = require(ServerScriptService:WaitForChild("PlayerDataSchema") :: ModuleScript)
local store = DataStoreService:GetDataStore("PlayerData") -- the SAME name as before

local function load(player: Player)
	local ok, stored = pcall(function()
		return store:GetAsync(`Player_{player.UserId}`)
	end)
	if not ok then
		player:Kick("Your data could not be loaded. Please rejoin.") -- never default on failure
		return nil
	end
	if stored == nil then
		return PlayerDataSchema.default() -- a genuinely new player
	end
	local migrated, result = pcall(PlayerDataSchema.migrate, stored)
	if not migrated then
		player:Kick("This server is out of date. Please rejoin.") -- a newer save; do not touch it
		return nil
	end
	return result
end
```

**Verification:** run the module against saves of every version before shipping. `execute_luau`
can `require` it and assert: a v1 save `{ Coins = 5, inventory = { "Sword", "Sword", "Shield" } }`
becomes `{ version = 3, coins = 5, gems = 0, inventory = { Sword = 2, Shield = 1 } }` with no
`Coins` key; a v3 save comes back unchanged; a v4 save errors. Then round-trip one save through a
throwaway store name (not the live one) with `SetAsync`, `GetAsync` and `migrate`. (Run exactly this
way in Studio 0.742, 2026-10-11: all four matched.)

---

## 8. Open a menu from an Input Action

**Trigger:** "press B to open the shop", "a gamepad button that toggles the inventory", "make my
menu work on console and mobile".

**Not this:**
- What happens when the player *buys* from that menu → example 1 or example 6; the toggle itself
  never needs the server
- Rebinding UI: `GetInputBindings()` is `RobloxScriptSecurity`; use `PreferredBinding` +
  `InputActionLabel` (`project-structure.md`)
- Turning IAS on for the default character controls: `PlayerScriptsUseInputActionSystem` is a
  Properties-window setting no script can touch

**Routing:** `project-structure.md` (IAS) + `ui-systems.md`.

**Sequence:**

1. **Build the action at edit time** (IAS is declarative): under `ReplicatedStorage/Inputs/
   PlayContext` (an `InputContext`), add an `InputAction` named `ToggleShop` (`Type = Bool`) with
   one `InputBinding` per device family: `KeyCode = B` for keyboard, `KeyCode = ButtonY` for
   gamepad, and for touch an `InputBinding` whose `UIButton` points at an on-screen button.
2. **Listen to the action, not the key.** One `Pressed` handler covers every device.
3. **The toggle is client-only.** Opening a menu changes nothing anyone else can see.

```luau
--!strict
--@skilltest: client
-- StarterPlayerScripts/ShopToggle.client.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local shopGui = playerGui:WaitForChild("ShopGui") :: ScreenGui
local inputs = ReplicatedStorage:WaitForChild("Inputs")
local toggleShop = inputs:WaitForChild("PlayContext"):WaitForChild("ToggleShop") :: InputAction

shopGui.Enabled = false
toggleShop.Pressed:Connect(function()
	shopGui.Enabled = not shopGui.Enabled
end)
```

**Verification:** in a playtest, press the real key with MCP `user_keyboard_input` (focus the game
view first) and read `shopGui.Enabled` from `execute_luau` (Client) after each press: `false`, then
`true`, then `false`. (Run exactly this way in Studio 0.742, 2026-10-11, with the hierarchy above
and `PlayerScriptsUseInputActionSystem` left at its default.) If nothing toggles, check that the
`InputContext` is `Enabled` and that a higher-`Priority` context with `Sink` is not consuming the
key.

---

## 9. Concept Image to 3D Asset, Physics Contraption, and Playtest

**Trigger:** "Turn this concept image into a 3D hover crate / checkpoint pad and make it work",
"generate a 3D prop from an image, attach physics, and verify it in a playtest".

**Not this:**
- Importing an already-modeled `.fbx`/`.gltf` from Blender or Maya → `file-formats-and-assets.md` +
  `get_roblox_skill("rbx-import-asset")`
- Multiplayer vehicle replication or client-authority anti-exploit design → `networking.md` +
  `security-hardening.md`
- Generating a static decorative prop with no runtime behavior → stop after generation +
  `screen_capture` (no playtest loop needed)

**Routing:** `mcp-integration.md` (Workflows #6 & #7) + `agent-safety.md` before generating or
replacing existing assets.

**Sequence:**

1. **Stage the local concept image first.** Call `store_image` with an absolute path to a local
   `.png` / `.jpg` / `.jpeg` (≤5 MB) → returns `IMAGEID_<id>`. (Never call `upload_image` for a
   local file; `upload_image` fetches HTTP(S) URLs.)
2. **Generate the 3D asset and poll until completion.** Call `generate_procedural_model` with
   `attachedImageUri`, `async: true`, and either `segmentation: "auto"` or `"explicit"` (≤8
   `partNames`) — or `generate_mesh` / `generate_material`. Because external MCP clients cap
   `wait_job_finished` at **45 s** per call while Studio 0.748 jobs run ~24–107 s, loop
   `wait_job_finished(jobId)` while `status == "Running"`.
3. **Post-process safely.** Before `generate_texture`, duplicate the target (it replaces in place).
   If calling `segment_mesh`, pass a **single `MeshPart`** (`instance_path`), never a
   multi-MeshPart `Model` (fails with `SegmentRequiresSingleMeshPart` in Studio 0.748).
4. **Add the `--!strict` physics & sensor logic** and record telemetry on `ServerStorage`
   attributes so playtest assertions do not depend on `LogService` (512-line truncation).

<!-- skilltest: defs-behind; prelude hover-crate; expect hover-crate -->
```luau
--!strict
-- ServerScriptService/HoverCrateContraption.server.luau
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local crate = Workspace:WaitForChild("HoverCrate") :: Model
local body = crate:WaitForChild("Body") :: BasePart
local checkpoint = Workspace:WaitForChild("MarginCheckpoint") :: BasePart

local attachment = Instance.new("Attachment")
attachment.Parent = body

local alignPos = Instance.new("AlignPosition")
alignPos.Mode = Enum.PositionAlignmentMode.OneAttachment
alignPos.Attachment0 = attachment
alignPos.MaxForce = 40_000
alignPos.Responsiveness = 18
alignPos.Position = body.Position + Vector3.new(0, 2, 0)
alignPos.Parent = body

local alignOri = Instance.new("AlignOrientation")
alignOri.Mode = Enum.OrientationAlignmentMode.OneAttachment
alignOri.Attachment0 = attachment
alignOri.MaxTorque = 25_000
alignOri.Responsiveness = 15
alignOri.CFrame = CFrame.identity
alignOri.Parent = body

local thinParams = RaycastParams.new()
thinParams.FilterType = Enum.RaycastFilterType.Include
thinParams.FilterDescendantsInstances = { checkpoint }

local thickParams = RaycastParams.new()
thickParams.FilterType = Enum.RaycastFilterType.Include
thickParams.FilterDescendantsInstances = { checkpoint }
thickParams.Margin = 2.0

local minY = math.huge
local maxY = -math.huge
local thinHits = 0
local thickHits = 0

local heartbeatConn: RBXScriptConnection
heartbeatConn = RunService.Heartbeat:Connect(function()
	if not crate.Parent then
		heartbeatConn:Disconnect()
		return
	end

	local y = body.Position.Y
	if y < minY then
		minY = y
	end
	if y > maxY then
		maxY = y
	end

	local origin = checkpoint.Position + Vector3.new(1.2, 5, 0)
	local direction = Vector3.new(0, -10, 0)
	if Workspace:Raycast(origin, direction, thinParams) then
		thinHits += 1
	end
	if Workspace:Raycast(origin, direction, thickParams) then
		thickHits += 1
	end

	local triggered = false
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			if (root.Position - checkpoint.Position).Magnitude <= 6 then
				triggered = true
				break
			end
		end
	end

	ServerStorage:SetAttribute("HoverMinY", minY)
	ServerStorage:SetAttribute("HoverMaxY", maxY)
	ServerStorage:SetAttribute("ThinHits", thinHits)
	ServerStorage:SetAttribute("ThickHits", thickHits)
	if triggered then
		ServerStorage:SetAttribute("PlayerTriggered", true)
	end
end)
```

5. **Run the automated playtest loop.** Call `start_stop_play` → drive inputs (`user_keyboard_input`
   and/or `character_navigation` to a navmesh-reachable floor coordinate near the checkpoint) →
   assert `ServerStorage` attributes via `execute_luau` (`Server`) → capture the live view with
   `screen_capture` (keep primary over `video_capture`, which failed with `Target is not reachable`
   in Studio 0.748.0.7481526 Play `Client`) → `start_stop_play` to stop.

**Verification:** `execute_luau` (`Server`) confirms `HoverMinY < HoverMaxY`, `ThinHits == 0`,
`ThickHits > 0`, and `PlayerTriggered == true`; `get_console_output` reports 0 errors;
`screen_capture` shows the generated crate hovering cleanly above the floor.

---

## 10. Auto-Route to Built-in Studio Skills and Verify Stale Steps

**Trigger:** Any Studio task that overlaps Roblox's 17 built-in `rbx-*` skills — device-size UI
testing, network latency/loss simulation, MicroProfiler or Luau heap leaks, `SceneAnalysisService`,
streaming conversion, `InputActionSystem`, analytics, `ProcessReceipt` auditing, Open Cloud,
permissions, unit tests, or `ConfigService`.

**Not this:**
- `--!strict` Luau type errors, DataStore session locking, or server-authoritative `RemoteEvent`
  design → read this repo's `references/*.md` directly (`rbx-*` skills do not cover them)
- A host whose live tool list still exposes `list_skills` / `skill` (Studio 0.745–0.746) → use
  those names instead when `list_roblox_skills` / `get_roblox_skill` are absent

**Routing:** `mcp-integration.md` (17-skill matrix) + the paired `roblox-dev-skill` reference for
the domain.

**Sequence:**

```text
1. list_roblox_studios  → pin studio_id once
2. list_roblox_skills   → inspect the live 17 rbx-* skills before improvising
3. get_roblox_skill     → load each matching rbx-* skill (e.g., rbx-device-simulator-lua, rbx-network-simulator)
4. Cross-check steps    → patch stale tool/API advice against mcp-integration.md before running:
                          • pass studio_id on every call (never phantom set_active_studio)
                          • call get_roblox_skill (never old skill) and ask user directly (never ask_questions)
                          • use Client execute_luau for LocalPlayer.PlayerGui / AbsoluteSize (works in Play)
                          • run SceneAnalysisService in Edit when static counts suffice; run HeapProfiler in Play Server
                          • record & restore settings().Network (persists across restarts and clamps silently)
5. Run & verify         → execute_luau / get_console_output / screen_capture, then restore persistent Studio settings
```

**Verification:** Confirm the target inspection or test succeeded with 0 errors in
`get_console_output`, and if `rbx-network-simulator` touched `settings().Network`, read the
properties back via `execute_luau` to confirm they are restored to `0`.

---

## Anti-patterns these examples exist to prevent

| Anti-pattern | What to do instead |
|---|---|
| Generating code and declaring the task done | Run the verification section. "It compiles" is not "it works" |
| Testing only the happy path | The validation exists for the unhappy path — fire junk at it |
| Matching a sample because the words look similar | Read **Not this** first; half these examples route elsewhere on a small detail |
| Writing a member name from memory | Example 4. The dump is one `jq` away |
| Reading `Security` and ignoring `Capabilities` and `Tags` | All three gate whether your line runs |
| `multi_edit` during a playtest, or without `script_read` | `Edit` datamodel only; `old_string` is exact-match |
| Quietly doing the insecure thing because the user asked | Example 5 — name it, offer the alternative, let them decide |
