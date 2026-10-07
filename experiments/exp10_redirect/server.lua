local BASE = 'http://127.0.0.1:8099'

local function req(label, path, opts)
	PerformHttpRequest(BASE .. path, function(status, body)
		print(('[exp10] %-34s status=%s body=%s'):format(label, tostring(status), tostring(body):sub(1, 12)))
	end, 'GET', '', {}, opts)
end

RegisterCommand('exp10_run', function()
	req('/start  (default options)', '/start', nil)
	req('/start  followLocation=true', '/start', { followLocation = true })
	req('/start  followLocation=false', '/start', { followLocation = false })
	req('/cross  followLocation=true', '/cross', { followLocation = true })
	req('/loop   followLocation=true', '/loop', { followLocation = true })
end, true)

-- Low-level call WITHOUT the followLocation key (bypasses the Lua default set in scheduler.lua).
-- The response is not observable here (no dispatcher); check the python console for a /final HIT.
RegisterCommand('exp10_raw', function()
	local id = PerformHttpRequestInternalEx({ url = BASE .. '/start', method = 'GET', data = '', headers = {} })
	print('[exp10] raw call sent, request id = ' .. tostring(id) .. ' -> look for "HIT ... /final" in the python console')
end, true)
print('[exp10] ready, run: exp10_run  then  exp10_raw')
