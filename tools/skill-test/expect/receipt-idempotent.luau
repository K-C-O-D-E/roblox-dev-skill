-- expect: each receipt is granted exactly once through the session owner: on top of a stored balance and unsaved earnings, across a session save and re-delivery, and for a nested Inventory grant after a failed write, a transform retry and a write that commits and then raises an error. Malformed, not-ready, unknown-product, absent-player and false-returning calls return NotProcessedYet and change nothing.
local skilltestPlayers = game:GetService("Players")
local skilltestHttp = game:GetService("HttpService")
local skilltestDataStoreService = game:GetService("DataStoreService")
local skilltestPlayer = skilltestPlayers:GetPlayers()[1] or skilltestPlayers.PlayerAdded:Wait()

local testStore = skilltestDataStoreService:GetDataStore("SkillTest_Receipt_" .. skilltestHttp:GenerateGUID(false))
ReceiptHandler.setDataStore(testStore)

-- A test double around testStore. Each entry of `failures` sets how one UpdateAsync call fails:
-- "beforeWrite" runs the transform, then raises an error without a write.
-- "transformRetry" runs the transform 1 extra time and discards the result, as UpdateAsync does
-- when another server wrote the key, then writes.
-- "afterWrite" writes, then raises an error, as a request that times out after the commit.
local failures: { string } = {}
local flakyStore = {}
function flakyStore.GetAsync(_self: any, key: string)
	return testStore:GetAsync(key)
end
function flakyStore.UpdateAsync(_self: any, key: string, transform: any)
	local failure = table.remove(failures, 1)
	if failure == "beforeWrite" or failure == "transformRetry" then
		local value, keyInfo = testStore:GetAsync(key)
		transform(value, keyInfo)
	end
	if failure == "beforeWrite" then
		error("simulated DataStore error before the write")
	end
	local result, keyInfo = testStore:UpdateAsync(key, transform)
	if failure == "afterWrite" then
		error("simulated DataStore error after the write")
	end
	return result, keyInfo
end

local playerKey = `Player_{skilltestPlayer.UserId}`
local initialCoins = 500
local earnedCoins = 25
local initialGems = 7
testStore:SetAsync(playerKey, {
	Coins = initialCoins,
	Gems = initialGems,
	Inventory = {},
	ProcessedReceipts = {},
})

local function newReceipt(productId: number, playerId: number?)
	return {
		PurchaseId = "skilltest-" .. skilltestHttp:GenerateGUID(false),
		PlayerId = playerId or skilltestPlayer.UserId,
		ProductId = productId,
	}
end

local function readStore(): any
	return (testStore:GetAsync(playerKey))
end

local function readSession(): any
	return ReceiptHandler.getSessionRecord(skilltestPlayer)
end

local function countPotions(record: any): number
	local count = 0
	if typeof(record) == "table" and typeof(record.Inventory) == "table" then
		for _, item in record.Inventory do
			if item == "Potion" then
				count += 1
			end
		end
	end
	return count
end

local receipt = newReceipt(COINS_100)

-- Row 1: malformed receipt
__skilltest.eq("row 1: malformed receipt -> NotProcessedYet",
	ReceiptHandler.process({}), Enum.ProductPurchaseDecision.NotProcessedYet)

-- Row 2: session not loaded yet
__skilltest.eq("row 2: no session / leaderstats yet -> NotProcessedYet (retried later)",
	ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.NotProcessedYet)

local leaderstats = Instance.new("Folder")
leaderstats.Name = "leaderstats"
local coins = Instance.new("IntValue")
coins.Name = "Coins"
coins.Value = 0
coins.Parent = leaderstats
leaderstats.Parent = skilltestPlayer

__skilltest.eq("loadSession succeeds", ReceiptHandler.loadSession(skilltestPlayer), true)
__skilltest.eq("loadSession mirrored initial Coins", coins.Value, initialCoins)
__skilltest.eq("addCoins adds unsaved gameplay earnings", ReceiptHandler.addCoins(skilltestPlayer, earnedCoins), true)
__skilltest.eq("leaderstats reflects unsaved gameplay earnings", coins.Value, initialCoins + earnedCoins)

-- Row 3: unknown ProductId
__skilltest.eq("row 3: unknown ProductId -> NotProcessedYet",
	ReceiptHandler.process(newReceipt(999999999)), Enum.ProductPurchaseDecision.NotProcessedYet)

-- Row 4: PlayerId not in the server
__skilltest.eq("row 4: absent PlayerId -> NotProcessedYet",
	ReceiptHandler.process(newReceipt(COINS_100, -999999999)), Enum.ProductPurchaseDecision.NotProcessedYet)

-- Row 5: valid receipt on top of stored balance + unsaved earnings, then follow-up saveSession
local expectedCoins = initialCoins + earnedCoins + 100
__skilltest.eq("row 5: ready -> PurchaseGranted",
	ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("row 5: leaderstats Coins preserves unsaved earnings + exact 100 grant", coins.Value, expectedCoins)

local storedAfterFirst = readStore()
__skilltest.check("row 5: durable record exists after first grant", typeof(storedAfterFirst) == "table")
__skilltest.eq("row 5: durable Coins equals stored + earned + 100", storedAfterFirst.Coins, expectedCoins)
__skilltest.eq("row 5: unrelated Gems field preserved after first grant", storedAfterFirst.Gems, initialGems)
__skilltest.eq("row 5: durable ProcessedReceipts has 1 entry", #storedAfterFirst.ProcessedReceipts, 1)
__skilltest.eq("row 5: durable ProcessedReceipts recorded PurchaseId", storedAfterFirst.ProcessedReceipts[1], receipt.PurchaseId)

__skilltest.eq("row 5: follow-up saveSession succeeds", ReceiptHandler.saveSession(skilltestPlayer), true)
local storedAfterSave = readStore()
__skilltest.eq("row 5: durable Coins survives follow-up session save", storedAfterSave.Coins, expectedCoins)
__skilltest.eq("row 5: unrelated Gems survives follow-up session save", storedAfterSave.Gems, initialGems)
__skilltest.eq("row 5: ProcessedReceipts survives follow-up session save", #storedAfterSave.ProcessedReceipts, 1)
__skilltest.eq("row 5: PurchaseId survives follow-up session save", storedAfterSave.ProcessedReceipts[1], receipt.PurchaseId)

-- Row 6: re-delivery of the same PurchaseId
__skilltest.eq("row 6: same PurchaseId again -> PurchaseGranted",
	ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("row 6: leaderstats Coins unchanged on re-delivery", coins.Value, expectedCoins)

local storedAfterRetry = readStore()
__skilltest.eq("row 6: durable Coins unchanged on re-delivery", storedAfterRetry.Coins, expectedCoins)
__skilltest.eq("row 6: unrelated Gems field preserved on re-delivery", storedAfterRetry.Gems, initialGems)
__skilltest.eq("row 6: durable ProcessedReceipts count unchanged on re-delivery", #storedAfterRetry.ProcessedReceipts, 1)

-- Row 7: handler returns false. The store, the session and leaderstats must stay as after row 6.
local FAILING_PRODUCT = 333333333
ReceiptHandler.handlers[FAILING_PRODUCT] = function(_record: any): boolean
	return false
end
__skilltest.eq("row 7: handler returns false -> NotProcessedYet",
	ReceiptHandler.process(newReceipt(FAILING_PRODUCT)), Enum.ProductPurchaseDecision.NotProcessedYet)
ReceiptHandler.handlers[FAILING_PRODUCT] = nil

local storedAfterRefusal = readStore()
__skilltest.eq("row 7: durable Coins unchanged after a false handler", storedAfterRefusal.Coins, expectedCoins)
__skilltest.eq("row 7: durable Gems unchanged after a false handler", storedAfterRefusal.Gems, initialGems)
__skilltest.eq("row 7: durable ProcessedReceipts unchanged after a false handler", #storedAfterRefusal.ProcessedReceipts, 1)
local sessionAfterRefusal = readSession()
__skilltest.eq("row 7: session Coins unchanged after a false handler", sessionAfterRefusal.Coins, expectedCoins)
__skilltest.eq("row 7: session ProcessedReceipts unchanged after a false handler", #sessionAfterRefusal.ProcessedReceipts, 1)
__skilltest.eq("row 7: leaderstats Coins unchanged after a false handler", coins.Value, expectedCoins)

-- Rows 8 to 12 use the test double, so that chosen UpdateAsync calls fail.
ReceiptHandler.setDataStore(flakyStore :: any)

-- Row 8: nested Inventory grant. UpdateAsync runs the transform, then raises an error before the write
local potionReceipt = newReceipt(POTION)
table.insert(failures, "beforeWrite")
__skilltest.eq("row 8: failed write -> NotProcessedYet",
	ReceiptHandler.process(potionReceipt), Enum.ProductPurchaseDecision.NotProcessedYet)
__skilltest.eq("row 8: store holds 0 Potion after the failed write", countPotions(readStore()), 0)
__skilltest.eq("row 8: session holds 0 Potion after the failed write", countPotions(readSession()), 0)
__skilltest.eq("row 8: session ProcessedReceipts unchanged after the failed write", #readSession().ProcessedReceipts, 1)

-- Row 9: re-delivery. UpdateAsync runs the transform 2 times and writes the second result
table.insert(failures, "transformRetry")
__skilltest.eq("row 9: retry after the failed write -> PurchaseGranted",
	ReceiptHandler.process(potionReceipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("row 9: store holds exactly 1 Potion", countPotions(readStore()), 1)
__skilltest.eq("row 9: session holds exactly 1 Potion", countPotions(readSession()), 1)
__skilltest.eq("row 9: session keeps the unsaved Coins", readSession().Coins, expectedCoins)

-- Row 10: session save, then a third delivery of the same PurchaseId
__skilltest.eq("row 10: saveSession succeeds", ReceiptHandler.saveSession(skilltestPlayer), true)
__skilltest.eq("row 10: store holds exactly 1 Potion after saveSession", countPotions(readStore()), 1)
__skilltest.eq("row 10: third delivery -> PurchaseGranted",
	ReceiptHandler.process(potionReceipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("row 10: store holds exactly 1 Potion after the third delivery", countPotions(readStore()), 1)
__skilltest.eq("row 10: session holds exactly 1 Potion after the third delivery", countPotions(readSession()), 1)
__skilltest.eq("row 10: durable ProcessedReceipts has 2 entries", #readStore().ProcessedReceipts, 2)

-- Row 11: a second Potion purchase. UpdateAsync writes, then raises an error
local secondPotionReceipt = newReceipt(POTION)
table.insert(failures, "afterWrite")
__skilltest.eq("row 11: error after the write -> NotProcessedYet",
	ReceiptHandler.process(secondPotionReceipt), Enum.ProductPurchaseDecision.NotProcessedYet)
__skilltest.eq("row 11: session holds 1 Potion", countPotions(readSession()), 1)

-- Row 12: re-delivery of the second Potion purchase, then a session save
__skilltest.eq("row 12: re-delivery -> PurchaseGranted",
	ReceiptHandler.process(secondPotionReceipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("row 12: session holds exactly 2 Potion", countPotions(readSession()), 2)
__skilltest.eq("row 12: saveSession succeeds", ReceiptHandler.saveSession(skilltestPlayer), true)
local storedAfterPotions = readStore()
__skilltest.eq("row 12: store holds exactly 2 Potion", countPotions(storedAfterPotions), 2)
__skilltest.eq("row 12: durable ProcessedReceipts has 3 entries", #storedAfterPotions.ProcessedReceipts, 3)
__skilltest.eq("row 12: durable Coins unchanged by the Potion grants", storedAfterPotions.Coins, expectedCoins)
__skilltest.eq("row 12: unrelated Gems preserved by the Potion grants", storedAfterPotions.Gems, initialGems)
__skilltest.eq("each simulated failure was used", #failures, 0)

ReceiptHandler.saveSession(skilltestPlayer, true)
ReceiptHandler.setDataStore(testStore)
leaderstats:Destroy()
