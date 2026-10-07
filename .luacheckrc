std = "lua54"
max_line_length = 120
codes = true
exclude_files = { "dev-server/", "experiments/", "**/fxmanifest.lua", "node_modules/", ".luarocks/", ".lua/", "lua_modules/" }

-- FiveM / Cfx globals used by torii.
globals = {
	"Citizen", "exports", "msgpack", "json",
	"PerformHttpRequest", "PerformHttpRequestInternal", "PerformHttpRequestInternalEx",
	"SaveResourceFile", "ExecuteCommand", "GetConvar", "SetHttpHandler",
}
read_globals = {
	"IsDuplicityVersion", "GetCurrentResourceName", "LoadResourceFile", "GetResourceMetadata",
	"GetNumResourceMetadata", "GetResourceState", "GetInvokingResource", "GetNumResources",
	"GetResourceByFindIndex", "TriggerEvent", "AddEventHandler", "RegisterCommand", "CancelEvent",
	"SetTimeout", "GetGameTimer", "GetConvarInt", "GetResourcePath", "GetNumResourceMetadata",
	"GetPlayerName", "CreateThread", "Wait", "GetHashKey",
}

files["spec/"] = {
	std = "+busted",
	-- tests install fake globals on purpose
	globals = { "load", "debug", "_G" },
	ignore = { "212", "213" },
}
