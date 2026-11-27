--!strict
-- Test double for the legacy DataStore2 module (datastore-persistence.md migration example).
-- -910004: existing valid table; -910005: verified absent (nil); -910006: repeated read failures
-- triggering backup (requires SetBackup); -910007: scalar legacy value; -910008: corrupt coins field.
return function(_name: string, player: Player)
	local userId = (player :: any).UserId
	local backupRetries: number? = nil
	local isBackup = false
	return {
		SetBackup = function(_self: any, retries: number)
			backupRetries = retries
		end,
		Get = function(_self: any, _default: any)
			if userId == -910006 then
				if backupRetries == nil or backupRetries < 1 then
					error("unbounded DataStore2 retry without SetBackup")
				end
				isBackup = true
				return { coins = 0, inventory = {} }
			end
			if userId == -910005 then
				return nil
			end
			if userId == -910007 then
				return 42
			end
			if userId == -910008 then
				return { coins = "corrupt", inventory = {} }
			end
			return { coins = 99, inventory = { "Bow" } }
		end,
		IsBackup = function(_self: any): boolean
			return isBackup
		end,
	}
end
