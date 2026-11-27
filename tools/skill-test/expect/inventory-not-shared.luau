-- expect: two new players get separate default tables, a player who left during load is not cached, and a rejoin during a pending departure save serializes cleanly without losing the new session.
local service = skilltestModule :: any
local function isPresent()
	return true
end
local function isGone()
	return false
end
local a = { UserId = -910001, Name = "SkillTestA", IsDescendantOf = isPresent } :: any
local b = { UserId = -910002, Name = "SkillTestB", IsDescendantOf = isPresent } :: any
local c = { UserId = -910003, Name = "SkillTestLeft", IsDescendantOf = isGone } :: any
service.loadData(a)
service.loadData(b)
service.loadData(c)
local da, db, dc = service.getData(a), service.getData(b), service.getData(c)
__skilltest.check("both players have session data", da ~= nil and db ~= nil)
__skilltest.eq("player who left during load is not cached", dc, nil)
if da and db then
	__skilltest.check("separate Inventory tables", da.Inventory ~= db.Inventory)
	table.insert(da.Inventory, "Sword")
	__skilltest.eq("an item given to A does not appear for B", #db.Inventory, 0)
	__skilltest.eq("defaults: 0 coins, level 1", `{db.Coins}/{db.Level}`, "0/1")
end

-- Rejoin during a pending departure save for the same UserId.
local rejoinUserId = -math.random(1000000, 9999999)
local departing = { UserId = rejoinUserId, Name = "SkillTestDepart", IsDescendantOf = isPresent } :: any
local rejoined = { UserId = rejoinUserId, Name = "SkillTestRejoin", IsDescendantOf = isPresent } :: any
service.loadData(departing)
local departingData = service.getData(departing)
__skilltest.check("departing session loaded", departingData ~= nil)
if departingData then
	departingData.Coins = 42
	local saveDone = false
	local loadDone = false
	task.spawn(function()
		service.saveData(departing)
		saveDone = true
	end)
	task.spawn(function()
		service.loadData(rejoined)
		loadDone = true
	end)
	local deadline = os.clock() + 10
	while not (saveDone and loadDone) and os.clock() < deadline do
		task.wait()
	end
	__skilltest.check("both departure save and rejoin load finished", saveDone and loadDone)
	__skilltest.eq("departing session cleared after save", service.getData(departing), nil)
	local rejoinedData = service.getData(rejoined)
	__skilltest.check("rejoined session stayed active", rejoinedData ~= nil)
	if rejoinedData then
		__skilltest.eq("rejoined session loaded saved Coins", rejoinedData.Coins, 42)
	end
end
