-- expect: two new players get separate default tables, and a player who left during load is not cached.
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
