local now = os.nanotime or function() return os.clock() * 1e9 end

local function bench(label, fn, n)
	for _ = 1, 10000 do fn() end -- warm-up
	collectgarbage(); collectgarbage()
	local t0 = now()
	for _ = 1, n do fn() end
	local dt = now() - t0
	print(('[exp08] %-34s %8.1f ns/call'):format(label, dt / n))
end

RegisterCommand('exp08_bench', function(_, args)
	local n = tonumber(args[1]) or 1000000
	local target = GetConvarInt -- a cheap, harmless native stub

	bench('baseline: stub called directly', function() return target('exp08_x', 0) end, n)

	local denied = { [0xDEAD0001] = true }
	local function filtered(name, ...)
		if denied[name] then return nil end
		return target(name, ...)
	end
	bench('wrapper: table lookup + vararg', function() return filtered('exp08_x', 0) end, n)

	local function with_site(name, ...)
		local info = debug.getinfo(2, 'Sl')
		local _ = info.short_src
		return target(name, ...)
	end
	bench('wrapper: + debug.getinfo(2,"Sl")', function() return with_site('exp08_x', 0) end, n)
end, true)
print('[exp08] ready, run: exp08_bench [iterations]')
