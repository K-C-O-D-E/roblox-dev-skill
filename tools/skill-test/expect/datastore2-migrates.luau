-- expect: old DataStore2 data merges once, genuine absence marks migrated, missing indexed value refuses migration, bounded repeated failures return backup and refuse migration, and unrecognized or malformed legacy values are rejected.
local skilltestDataStoreService = game:GetService("DataStoreService")

local profile = { Data = { coins = 0, inventory = {}, migrated = false } }
local fake = { UserId = -910004 } :: any
__skilltest.eq("existing record returns true", migrateFromDataStore2(fake, profile), true)
__skilltest.eq("coins merged from the old store", profile.Data.coins, 99)
__skilltest.eq("inventory merged", profile.Data.inventory[1], "Bow")
__skilltest.eq("marked migrated", profile.Data.migrated, true)
profile.Data.coins = 5
__skilltest.eq("a second call returns true", migrateFromDataStore2(fake, profile), true)
__skilltest.eq("a second call changes nothing", profile.Data.coins, 5)

local absentProfile = { Data = { coins = 0, inventory = {}, migrated = false } }
local absentPlayer = { UserId = -910005 } :: any
__skilltest.eq("verified absent old record returns true", migrateFromDataStore2(absentPlayer, absentProfile), true)
__skilltest.eq("verified absent old record marks migrated", absentProfile.Data.migrated, true)

local backupProfile = { Data = { coins = 0, inventory = {}, migrated = false } }
local backupPlayer = { UserId = -910006 } :: any
__skilltest.eq("bounded repeated read failure (backup) returns false", migrateFromDataStore2(backupPlayer, backupProfile), false)
__skilltest.eq("backup value does not mark migrated", backupProfile.Data.migrated, false)

local scalarProfile = { Data = { coins = 10, inventory = {}, migrated = false } }
local scalarPlayer = { UserId = -910007 } :: any
__skilltest.eq("unrecognized scalar legacy value returns false", migrateFromDataStore2(scalarPlayer, scalarProfile), false)
__skilltest.eq("unrecognized scalar does not mark migrated", scalarProfile.Data.migrated, false)
__skilltest.eq("unrecognized scalar leaves coins intact", scalarProfile.Data.coins, 10)

local corruptProfile = { Data = { coins = 10, inventory = {}, migrated = false } }
local corruptPlayer = { UserId = -910008 } :: any
__skilltest.eq("malformed legacy field returns false", migrateFromDataStore2(corruptPlayer, corruptProfile), false)
__skilltest.eq("malformed legacy field does not mark migrated", corruptProfile.Data.migrated, false)
__skilltest.eq("malformed legacy field leaves coins intact", corruptProfile.Data.coins, 10)

-- OrderedBackups index exists, but DataStore2:Get(nil) returned nil without IsBackup().
local indexedMissingStore = skilltestDataStoreService:GetOrderedDataStore("PlayerSave/-910009")
indexedMissingStore:SetAsync("1", 1)
local indexedMissingProfile = { Data = { coins = 10, inventory = {}, migrated = false } }
local indexedMissingPlayer = { UserId = -910009 } :: any
__skilltest.eq("missing indexed legacy value returns false", migrateFromDataStore2(indexedMissingPlayer, indexedMissingProfile), false)
__skilltest.eq("missing indexed legacy value does not mark migrated", indexedMissingProfile.Data.migrated, false)
__skilltest.eq("missing indexed legacy value leaves coins intact", indexedMissingProfile.Data.coins, 10)
