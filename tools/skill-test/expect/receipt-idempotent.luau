-- expect: a receipt is durably granted once, re-delivery does not grant twice, and not-ready stays retryable.
local skilltestPlayers = game:GetService("Players")
local skilltestPlayer = skilltestPlayers:GetPlayers()[1] or skilltestPlayers.PlayerAdded:Wait()
local receipt = {
	PurchaseId = "skilltest-" .. game:GetService("HttpService"):GenerateGUID(false),
	PlayerId = skilltestPlayer.UserId,
	ProductId = COINS_100,
}
__skilltest.eq("no leaderstats yet -> NotProcessedYet (retried later)",
	ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.NotProcessedYet)
local leaderstats = Instance.new("Folder")
leaderstats.Name = "leaderstats"
local coins = Instance.new("IntValue")
coins.Name = "Coins"
coins.Parent = leaderstats
leaderstats.Parent = skilltestPlayer
local unknownReceipt = {
	PurchaseId = "skilltest-" .. game:GetService("HttpService"):GenerateGUID(false),
	PlayerId = skilltestPlayer.UserId,
	ProductId = 999999999,
}
__skilltest.eq("unknown ProductId -> NotProcessedYet",
	ReceiptHandler.process(unknownReceipt), Enum.ProductPurchaseDecision.NotProcessedYet)
__skilltest.eq("ready -> PurchaseGranted", ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.PurchaseGranted)
local afterFirst = coins.Value
__skilltest.check("coins increased by at least 100 after first grant", afterFirst >= 100)
__skilltest.eq("same PurchaseId again -> PurchaseGranted", ReceiptHandler.process(receipt), Enum.ProductPurchaseDecision.PurchaseGranted)
__skilltest.eq("coins are not granted twice on re-delivery", coins.Value, afterFirst)
leaderstats:Destroy()
