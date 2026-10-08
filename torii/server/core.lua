-- torii core resource (server side).
--
-- It does NOT intercept anything itself (each resource has its own Lua state, so interception happens in
-- torii/init.lua inside every protected resource). The core:
--   * receives reports from protected resources (exports.torii:report), attributes them with
--     GetInvokingResource(), rate-limits them, prints alerts and appends JSON lines to logs/torii.jsonl;
--   * runs the manifest gate: on onResourceStarting it checks that a resource with server code includes
--     '@torii/init.lua' first (and flags JavaScript / C# server scripts, which torii cannot inspect);
--   * checks that protected resources really ran init.lua (attestation);
--   * prints a coverage summary at boot.
--
-- Convars:  set torii_mode "observe" | "enforce"      (default observe)
--           set torii_allow_private 1                 (development only: allow localhost / private ranges)

local LOG_FILE = '@torii/logs/torii.jsonl'
local INIT_LINE = '@torii/init.lua'
local GATE_DELAY_MS = 5000
local COVERAGE_DELAY_MS = 8000

-- Cfx / txAdmin built-ins that ship without torii. Admins can extend this with "exempt" in the lockfile.
local BUILTIN_EXEMPT = {
	monitor = true,
	sessionmanager = true,
	mapmanager = true,
	spawnmanager = true,
	chat = true,
	hardcap = true,
	baseevents = true,
	webadmin = true,
	fivem = true,
	rconlog = true,
	playernames = true,
}

-- Module loader (same idea as init.lua) --------------------------------------------------------------

local modules = {}
local function req(name)
	if modules[name] then
		return modules[name]
	end
	local source = LoadResourceFile('torii', 'src/' .. name .. '.lua')
	assert(source, 'torii: missing module ' .. name)
	local chunk, err = load(source, '@@torii/src/' .. name .. '.lua', 't')
	assert(chunk, err)
	modules[name] = chunk(req)
	return modules[name]
end

local policy_module = req('policy')

local function current_mode()
	return GetConvar('torii_mode', 'observe') == 'enforce' and 'enforce' or 'observe'
end

local function load_policy()
	local text = LoadResourceFile('torii', 'policy.lock.json')
	local lock
	if text then
		local ok, decoded = pcall(json.decode, text)
		if ok then
			lock = decoded
		else
			print('^1[torii] policy.lock.json is not valid JSON: every resource will be treated as having no grants^7')
		end
	end
	return policy_module.new(lock, { allow_private = GetConvar('torii_allow_private', '0') == '1' })
end

local policy = load_policy()

-- Logging ----------------------------------------------------------------------------------------------

local log_handle

local function write_log(event)
	local ok, line = pcall(json.encode, event)
	if not ok then
		return
	end
	if not log_handle then
		log_handle = io.open(LOG_FILE, 'a')
	end
	if log_handle then
		local wrote = pcall(function()
			log_handle:write(line, '\n')
			log_handle:flush()
		end)
		if not wrote then
			log_handle = nil
		end
	end
end

local FIELDS = { 'type', 'api', 'decision', 'reason', 'target', 'src', 'level', 'mode', 'origin' }

local function sanitize(event, resource)
	local clean = { resource = resource, ts = os.date('!%Y-%m-%dT%H:%M:%SZ') }
	for _, key in ipairs(FIELDS) do
		local value = event[key]
		if type(value) == 'string' then
			-- reports come from resources we do not trust: no control characters in anything we log or print
			clean[key] = (value:sub(1, 200):gsub('[%c\127]', '?'))
		end
	end
	return clean
end

local LABELS = { deny = '^1BLOCKED^7', would_deny = '^3WOULD BLOCK^7' }

local function alert(e)
	local label = LABELS[e.decision]
	if not label and e.level ~= 'warn' then
		return
	end
	print(
		('^3[torii]^7 %s  %s  %s %s -> %s  (%s)%s'):format(
			label or 'NOTICE',
			e.resource,
			e.type or '?',
			e.api or '',
			e.target or '',
			e.reason or '',
			e.src and ('  at ' .. e.src) or ''
		)
	)
end

local function record(resource, event)
	local e = sanitize(event, resource)
	write_log(e)
	alert(e)
	return e
end

-- Rate limiting (a hostile resource must not be able to flood the log) --------------------------------

local CAPACITY, REFILL_PER_SEC = 60, 30
local buckets = {}

local function allow_report(resource)
	local now = GetGameTimer()
	local b = buckets[resource]
	if not b then
		b = { tokens = CAPACITY, last = now, dropped = 0 }
		buckets[resource] = b
	end
	b.tokens = math.min(CAPACITY, b.tokens + (now - b.last) / 1000 * REFILL_PER_SEC)
	b.last = now
	if b.tokens >= 1 then
		b.tokens = b.tokens - 1
		if b.dropped > 0 then
			local dropped = b.dropped
			b.dropped = 0
			record(resource, {
				type = 'rate_limited',
				decision = 'allow',
				level = 'warn',
				reason = 'reports_dropped',
				target = tostring(dropped),
			})
		end
		return true
	end
	b.dropped = b.dropped + 1
	return false
end

-- Reports from protected resources -------------------------------------------------------------------

local attested = {}

exports('report', function(event)
	local resource = GetInvokingResource()
	if not resource or type(event) ~= 'table' then
		return
	end
	if event.type == 'attest' then
		attested[resource] = GetGameTimer()
	end
	if allow_report(resource) then
		record(resource, event)
	end
end)

-- Manifest inspection ---------------------------------------------------------------------------------

local function list_metadata(resource, key)
	local out = {}
	for i = 0, (GetNumResourceMetadata(resource, key) or 0) - 1 do
		out[#out + 1] = GetResourceMetadata(resource, key, i)
	end
	return out
end

local function extension_of(pattern)
	return (pattern:lower():match('%.([%w]+)$'))
end

--- Summarises what kind of server code a resource declares.
local function inspect(resource)
	local info = { has_server_code = false, protected = false, lua = 0, js = 0, csharp = 0 }
	local shared = list_metadata(resource, 'shared_script')
	info.protected = shared[1] == INIT_LINE
	local all = shared
	for _, entry in ipairs(list_metadata(resource, 'server_script')) do
		all[#all + 1] = entry
	end
	for _, entry in ipairs(all) do
		if type(entry) == 'string' and entry:sub(1, 1) ~= '@' then
			info.has_server_code = true
			local ext = extension_of(entry)
			if ext == 'lua' then
				info.lua = info.lua + 1
			elseif ext == 'js' or ext == 'ts' then
				info.js = info.js + 1
			elseif ext == 'dll' or ext == 'cs' then
				info.csharp = info.csharp + 1
			else
				info.lua = info.lua + 1 -- globs such as "server/*": assume Lua, the attestation check will tell
			end
		end
	end
	return info
end

local function is_exempt(resource)
	return resource == 'torii' or BUILTIN_EXEMPT[resource] == true or policy:is_exempt(resource)
end

-- Manifest gate ---------------------------------------------------------------------------------------

AddEventHandler('onResourceStarting', function(resource)
	attested[resource] = nil
	if is_exempt(resource) then
		return
	end
	local info = inspect(resource)
	if not info.has_server_code then
		return
	end
	local enforce = current_mode() == 'enforce'
	local refuse = false

	if not info.protected then
		refuse = enforce
		record('torii', {
			type = 'manifest_gate',
			api = 'onResourceStarting',
			level = 'warn',
			decision = enforce and 'deny' or 'would_deny',
			reason = 'missing_torii_init_line',
			target = resource,
		})
	end
	if info.js + info.csharp > 0 then
		refuse = refuse or enforce
		record('torii', {
			type = 'manifest_gate',
			api = 'onResourceStarting',
			level = 'warn',
			decision = enforce and 'deny' or 'would_deny',
			reason = 'unsupported_runtime_js_or_csharp',
			target = resource,
		})
	end
	if refuse then
		CancelEvent()
	end
end)

-- Attestation: a resource that declares the init line must have reported in -----------------------------

AddEventHandler('onResourceStart', function(resource)
	if is_exempt(resource) then
		return
	end
	local info = inspect(resource)
	if not (info.has_server_code and info.protected) then
		return
	end
	SetTimeout(GATE_DELAY_MS, function()
		if GetResourceState(resource) == 'started' and not attested[resource] then
			record('torii', {
				type = 'attestation',
				api = 'onResourceStart',
				level = 'warn',
				decision = 'allow',
				reason = 'protected_resource_never_reported',
				target = resource,
			})
		end
	end)
end)

-- Coverage summary -----------------------------------------------------------------------------------

local function coverage()
	local protected, unprotected, js_cs, exempt, no_code = {}, {}, {}, {}, {}
	for i = 0, GetNumResources() - 1 do
		local name = GetResourceByFindIndex(i)
		if name and GetResourceState(name) == 'started' then
			local info = inspect(name)
			if is_exempt(name) then
				exempt[#exempt + 1] = name
			elseif not info.has_server_code then
				no_code[#no_code + 1] = name
			else
				if info.protected then
					protected[#protected + 1] = name
				else
					unprotected[#unprotected + 1] = name
				end
				if info.js + info.csharp > 0 then
					js_cs[#js_cs + 1] = name
				end
			end
		end
	end
	table.sort(unprotected)
	table.sort(js_cs)
	print(
		('^3[torii]^7 mode=%s  protected=%d  unprotected=%d  js/c#=%d  exempt=%d  no-server-code=%d'):format(
			current_mode(),
			#protected,
			#unprotected,
			#js_cs,
			#exempt,
			#no_code
		)
	)
	if #unprotected > 0 then
		print('^3[torii]^7 not protected (run `torii install`): ' .. table.concat(unprotected, ', '))
	end
	if #js_cs > 0 then
		print('^3[torii]^7 JavaScript/C# server code torii cannot inspect: ' .. table.concat(js_cs, ', '))
	end
	for _, warning in ipairs(policy.warnings) do
		print('^3[torii]^7 lockfile warning: ' .. warning)
	end
	record('torii', {
		type = 'coverage',
		decision = 'allow',
		level = 'info',
		reason = 'summary',
		target = ('protected=%d unprotected=%d jscs=%d'):format(#protected, #unprotected, #js_cs),
	})
end

CreateThread(function()
	Wait(COVERAGE_DELAY_MS)
	coverage()
end)

RegisterCommand('torii_status', coverage, true)

AddEventHandler('onResourceStop', function(resource)
	if resource == 'torii' and log_handle then
		pcall(function()
			log_handle:close()
		end)
	end
end)

print(('^3[torii]^7 core started in %s mode'):format(current_mode()))
