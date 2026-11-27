-- expect: a receipt is durably granted once through the session writer on top of an existing balance and unsaved earnings, survives a follow-up session save, keeps unrelated fields intact, resists re-delivery, and returns NotProcessedYet for malformed, not-ready, false-returning, unknown-product, and absent-player calls.
local skilltestPlayers = game:GetService("Players")
local skilltestHttp = game:GetService("HttpService")
local skilltestDataStoreService = game:GetService("DataStoreService")
local skilltestPlayer = skilltestPlayers:GetPlayers()[1] or skilltestPlayers.PlayerAdded:Wait()

local testStore = skilltestDataStoreService:GetDataStore("SkillTest_Receipt_" .. skilltestHttp:GenerateGUID(false))
ReceiptHandler.setDataStore(testStore)

local playerKey = `Player_{skilltestPlayer.UserId}`
local initialCoins = 500
local earnedCoins = 25
local initialGems = 7
testStore:SetAsync(playerKey, {
	Coins = initialCoins,
	Gems = initialGems,
	ProcessedReceipts = {},
})

local receipt = {
	PurchaseId = "skilltest-" .. skilltestHttp:GenerateGUID(false),
	PlayerId = skilltestPlayer.UserId,
	ProductId = COINS_100,
}

-- Row 1: malformed receipt
__skilltest.eq("malformed receipt -> NotProcessedYet",
	ReceiptHandler.process({}), Enum.ProductPurchaseDecision.NotProcessedYet)

-- Row 2: session not loaded yet
__skilltest.eq("no session / leaderstats yet -> NotProcessedYet (retried later)",
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

-- Row 6: unknown ProductId
local unknownReceipt = {
	PurchaseId = "skilltest-" .. skilltestHttp:GenerateGUID(false),
	PlayerId = skilltestPlayer.UserId,
	ProductId = 999999999,
}
__skilltest.eq("unknown ProductId -> NotProcessedYet",
	ReceiptHandler.process(unknownReceipt), Enum.ProductPurchaseDecision.NotProcessedYet)

-- Row 7: PlayerId not in the server
local absentPlayerReceipt = {
	PurchaseId = "skilltest-" .. skilltestHttp:GenerateGUID(false),
	PlayerId = -999999999,
	ProductId = COINS_100,
}
__skilltest.eq("absent PlayerId -> NotProcessedYet",
	ReceiptHandler.process(absentPlayerReceipt), Enum.ProductPurchaseDecision.NotProcessedYet)

-- Row 5: handler returns false
local FAILING_PRODUCT = 222222222
ReceiptHandler.handlers[FAILING_PRODUCT] = function(_record: any): boolean
	return false
end
local failingReceipt = {
	PurchaseId = "skilltest-" .. skilltestHttp:GenerateGUID(false),
	PlayerId = skilltestPlayer.UserId,
	ProductId = FAILING_PRODUCT,
}
__skilltest.eq("handler returns false -> NotProcessedYet",
	ReceiptHandler.process(failingReceipt), Enum.ProductPurchaseDecision.NotProcessedYet)
ReceiptHandler.handlers[FAILING_PRODUCT] = nil

-- Row 3: valid receipt on top of stored balance + unsaved earnings, then follow-up saveSession
local expectedCoins = initialCoins + earnedCoins + 100
__skilltest.eq("ready -> PurchaseGranted",
	ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("leaderstats Coins preserves unsaved earnings + exact 100 grant", coins.Value, expectedCoins)

local storedAfterFirst = testStore:GetAsync(playerKey)
__skilltest.check("durable record exists after first grant", typeof(storedAfterFirst) == "table")
__skilltest.eq("durable Coins equals stored + earned + 100", storedAfterFirst.Coins, expectedCoins)
__skilltest.eq("unrelated Gems field preserved after first grant", storedAfterFirst.Gems, initialGems)
__skilltest.eq("durable ProcessedReceipts has 1 entry", #storedAfterFirst.ProcessedReceipts, 1)
__skilltest.eq("durable ProcessedReceipts recorded PurchaseId", storedAfterFirst.ProcessedReceipts[1], receipt.PurchaseId)

__skilltest.eq("follow-up saveSession succeeds", ReceiptHandler.saveSession(skilltestPlayer), true)
local storedAfterSave = testStore:GetAsync(playerKey)
__skilltest.eq("durable Coins survives follow-up session save", storedAfterSave.Coins, expectedCoins)
__skilltest.eq("unrelated Gems survives follow-up session save", storedAfterSave.Gems, initialGems)
__skilltest.eq("ProcessedReceipts survives follow-up session save", #storedAfterSave.ProcessedReceipts, 1)
__skilltest.eq("PurchaseId survives follow-up session save", storedAfterSave.ProcessedReceipts[1], receipt.PurchaseId)

-- Row 4: re-delivery of the same PurchaseId
__skilltest.eq("same PurchaseId again -> PurchaseGranted",
	ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("leaderstats Coins unchanged on re-delivery", coins.Value, expectedCoins)

local storedAfterRetry = testStore:GetAsync(playerKey)
__skilltest.eq("durable Coins unchanged on re-delivery", storedAfterRetry.Coins, expectedCoins)
__skilltest.eq("unrelated Gems field preserved on re-delivery", storedAfterRetry.Gems, initialGems)
__skilltest.eq("durable ProcessedReceipts count unchanged on re-delivery", #storedAfterRetry.ProcessedReceipts, 1)

ReceiptHandler.saveSession(skilltestPlayer, true)
leaderstats:Destroy()
