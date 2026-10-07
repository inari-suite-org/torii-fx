local KEYS = { 'torii_http', 'torii_dynamic_code', 'torii_not_declared', 'shared_script', 'server_script' }

AddEventHandler('onResourceStarting', function(name)
	if name ~= 'exp02_victim' then return end
	print(('[exp02] onResourceStarting(%s) state=%s'):format(name, GetResourceState(name)))
	for _, key in ipairs(KEYS) do
		local n = GetNumResourceMetadata(name, key) or -1
		local values = {}
		for i = 0, n - 1 do values[#values + 1] = tostring(GetResourceMetadata(name, key, i)) end
		print(('[exp02]   %s: count=%d values=[%s]'):format(key, n, table.concat(values, ', ')))
	end
	if GetConvar('exp02_cancel', '0') == '1' then
		print('[exp02] calling CancelEvent()')
		CancelEvent()
	end
	SetTimeout(2000, function()
		print(('[exp02] 2s later, state of %s = %s'):format(name, GetResourceState(name)))
	end)
end)
print('[exp02] core ready')
