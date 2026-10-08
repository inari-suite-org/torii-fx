-- Prints what a command handler can tell about its caller. Nothing secret is printed: only the source number, the
-- invoking resource name and the argument the caller passed.
local function report(name)
	return function(source, args)
		print(('[exp11] %s ran: source=%s invoking=%s arg=%s'):format(
			name, tostring(source), tostring(GetInvokingResource()), tostring(args[1])))
	end
end

RegisterCommand('exp11_secure', report('exp11_secure (restricted)'), true)
RegisterCommand('exp11_open', report('exp11_open (unrestricted)'), false)

-- txAdmin events: who fired them (the real ones come from the "monitor" resource)
for _, name in ipairs({ 'consoleCommand', 'adminAuth' }) do
	AddEventHandler('txAdmin:events:' .. name, function(data)
		print(('[exp11] txAdmin:events:%s from invoking=%s author=%s'):format(
			name, tostring(GetInvokingResource()), type(data) == 'table' and tostring(data.author) or '?'))
	end)
end

print('[exp11] target ready: type "exp11_secure typed" and "exp11_open typed" in the console')
