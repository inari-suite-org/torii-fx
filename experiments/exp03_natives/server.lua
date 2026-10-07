local NAMES = {
	'PerformHttpRequestInternalEx', 'PerformHttpRequestInternal', 'ExecuteCommand',
	'SetHttpHandler', 'GetConvar', 'LoadResourceFile', 'SaveResourceFile', 'GetPlayerName',
}

local mt = getmetatable(_G)
print(('[exp03] _G has a metatable: %s | __index type: %s'):format(tostring(mt ~= nil), mt and type(mt.__index) or 'n/a'))
print('[exp03] metatable on _G = lazy natives_loader.lua mode; none = full natives_*.lua file mode')

for _, name in ipairs(NAMES) do
	local before = type(rawget(_G, name))
	local fn = _G[name] -- first access triggers lazy loading when applicable
	local after = type(rawget(_G, name))
	local info = type(fn) == 'function' and debug.getinfo(fn, 'S') or {}
	print(('[exp03] %-30s rawget before=%-8s after=%-8s what=%s source=%s'):format(
		name, before, after, tostring(info.what), tostring(info.source)))
end

local function hex(h) return ('0x%08X'):format(h & 0xFFFFFFFF) end
for _, name in ipairs({ 'PerformHttpRequestInternalEx', 'PERFORM_HTTP_REQUEST_INTERNAL_EX', 'performhttprequestinternalex' }) do
	print(('[exp03] GetHashKey(%q) = %s'):format(name, hex(GetHashKey(name))))
end
