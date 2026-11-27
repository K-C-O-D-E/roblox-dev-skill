--!strict
-- Test double for the legacy DataStore2 module (datastore-persistence.md migration example).
-- Returns an existing save for -910004, nil (verified absent) for -910005, and backup for -910006.
return function(_name: string, player: Player)
	local userId = (player :: any).UserId
	return {
		Get = function(_self: any, _default: any)
			if userId == -910005 then
				return nil
			end
			if userId == -910006 then
				return { coins = 0, inventory = {} }
			end
			return { coins = 99, inventory = { "Bow" } }
		end,
		IsBackup = function(_self: any): boolean
			return userId == -910006
		end,
	}
end
