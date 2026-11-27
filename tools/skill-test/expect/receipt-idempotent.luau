-- expect: a receipt is durably granted once on top of an existing balance, unrelated fields stay intact, re-delivery does not grant twice, and malformed or not-ready calls stay retryable.
local skilltestPlayers = game:GetService("Players")
local skilltestHttp = game:GetService("HttpService")
local skilltestDataStoreService = game:GetService("DataStoreService")
local skilltestPlayer = skilltestPlayers:GetPlayers()[1] or skilltestPlayers.PlayerAdded:Wait()

local testStore = skilltestDataStoreService:GetDataStore("SkillTest_Receipt_" .. skilltestHttp:GenerateGUID(false))
ReceiptHandler.setDataStore(testStore)

local playerKey = `Player_{skilltestPlayer.UserId}`
local initialCoins = 500
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

__skilltest.eq("malformed receipt -> NotProcessedYet",
	ReceiptHandler.process({}), Enum.ProductPurchaseDecision.NotProcessedYet)
__skilltest.eq("no leaderstats yet -> NotProcessedYet (retried later)",
	ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.NotProcessedYet)

local leaderstats = Instance.new("Folder")
leaderstats.Name = "leaderstats"
local coins = Instance.new("IntValue")
coins.Name = "Coins"
coins.Value = initialCoins
coins.Parent = leaderstats
leaderstats.Parent = skilltestPlayer

local unknownReceipt = {
	PurchaseId = "skilltest-" .. skilltestHttp:GenerateGUID(false),
	PlayerId = skilltestPlayer.UserId,
	ProductId = 999999999,
}
__skilltest.eq("unknown ProductId -> NotProcessedYet",
	ReceiptHandler.process(unknownReceipt), Enum.ProductPurchaseDecision.NotProcessedYet)

__skilltest.eq("ready -> PurchaseGranted",
	ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("leaderstats Coins increased by exactly 100", coins.Value, initialCoins + 100)

local storedAfterFirst = testStore:GetAsync(playerKey)
__skilltest.check("durable record exists after first grant", typeof(storedAfterFirst) == "table")
__skilltest.eq("durable Coins increased by exactly 100", storedAfterFirst.Coins, initialCoins + 100)
__skilltest.eq("unrelated Gems field preserved after first grant", storedAfterFirst.Gems, initialGems)
__skilltest.eq("durable ProcessedReceipts has 1 entry", #storedAfterFirst.ProcessedReceipts, 1)
__skilltest.eq("durable ProcessedReceipts recorded PurchaseId", storedAfterFirst.ProcessedReceipts[1], receipt.PurchaseId)

__skilltest.eq("same PurchaseId again -> PurchaseGranted",
	ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("leaderstats Coins unchanged on re-delivery", coins.Value, initialCoins + 100)

local storedAfterRetry = testStore:GetAsync(playerKey)
__skilltest.eq("durable Coins unchanged on re-delivery", storedAfterRetry.Coins, initialCoins + 100)
__skilltest.eq("unrelated Gems field preserved on re-delivery", storedAfterRetry.Gems, initialGems)
__skilltest.eq("durable ProcessedReceipts count unchanged on re-delivery", #storedAfterRetry.ProcessedReceipts, 1)

leaderstats:Destroy()
