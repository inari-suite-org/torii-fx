-- torii/init.lua
--
-- Include it as the FIRST script directive of a resource manifest:
--
--     shared_script '@torii/init.lua'
--
-- (`torii install` does this for you.)
--
-- Why the first line is a server-only guard: a `shared_script` runs on the client as well, and FXServer
-- runs every shared_script before every server_script of a resource, wherever they sit in the manifest
-- (verified in ResourceScriptingComponent.cpp and experiment 01). That ordering is what lets torii run
-- before any code of the resource it protects. torii only protects the server, so the client must skip it.
if not IsDuplicityVersion() then
	return
end

local resource = GetCurrentResourceName()
if resource == 'torii' then
	return
end

-- Capture everything we need NOW, before the wrappers are installed and before any code of this
-- resource can run.
local orig_load = load
local load_resource_file = LoadResourceFile
local get_convar = GetConvar
local get_num_metadata, get_metadata = GetNumResourceMetadata, GetResourceMetadata
local get_game_timer = GetGameTimer
local json_lib, msgpack_lib, debug_lib = json, msgpack, debug
local print_ = print
local pcall_, error_, tostring_ = pcall, error, tostring

local modules = {}
local function req(name)
	local module = modules[name]
	if module then
		return module
	end
	local source = load_resource_file('torii', 'src/' .. name .. '.lua')
	if not source then
		error_('torii: missing module ' .. name)
	end
	local chunk, err = orig_load(source, '@@torii/src/' .. name .. '.lua', 't')
	if not chunk then
		error_(err)
	end
	module = chunk(req)
	modules[name] = module
	return module
end

-- The core is not running (not started yet, or stopped): keep the console informed about what matters,
-- stay silent about routine events such as attestation.
local function report_fallback(event)
	if event.level == 'warn' then
		print_(
			('[torii] %s %s %s %s'):format(
				resource,
				tostring_(event.type),
				tostring_(event.decision),
				tostring_(event.reason)
			)
		)
	end
end

-- Report through the torii resource. The core attributes the event with GetInvokingResource(), so a
-- resource can only ever report about itself.
local function report(event)
	local ok = pcall_(function()
		exports.torii:report(event)
	end)
	if not ok then
		report_fallback(event)
	end
end

local ok, err = pcall_(function()
	local policy_module = req('policy')
	local guard = req('guard')

	local lock
	local lock_text = load_resource_file('torii', 'policy.lock.json')
	if lock_text then
		local decoded_ok, decoded = pcall_(json_lib.decode, lock_text)
		if decoded_ok then
			lock = decoded
		end
	end
	local policy = policy_module.new(lock, { allow_private = get_convar('torii_allow_private', '0') == '1' })

	local result = guard.install({
		G = _G,
		resource = resource,
		policy = policy,
		debug = debug_lib,
		orig_load = orig_load,
		json_decode = json_lib.decode,
		json_encode = json_lib.encode,
		msgpack_unpack = msgpack_lib.unpack,
		msgpack_pack = msgpack_lib.pack,
		now = get_game_timer,
		mode = function()
			return get_convar('torii_mode', 'observe') == 'enforce' and 'enforce' or 'observe'
		end,
		report = report,
	})

	for _, failure in ipairs(result.failures) do
		report({
			type = 'internal_error',
			decision = 'allow',
			level = 'warn',
			reason = 'install_failure',
			target = failure,
		})
	end

	-- Compare what the manifest declares now with what the admin approved.
	local declaration = policy_module.read_declaration(get_num_metadata, get_metadata, resource)
	local grants = policy:grants(resource)
	local declares_something = #declaration.http > 0 or declaration.dynamic_code or declaration.follow_redirects
	local declared_hash = policy_module.declaration_hash(declaration)
	if grants and grants.declaration_hash and grants.declaration_hash ~= declared_hash then
		report({
			type = 'declaration',
			decision = 'allow',
			level = 'warn',
			reason = 'declaration_changed_since_approval',
			target = declared_hash:sub(1, 12),
		})
	elseif not grants and declares_something then
		report({
			type = 'declaration',
			decision = 'allow',
			level = 'warn',
			reason = 'declaration_not_approved',
			target = declared_hash:sub(1, 12),
		})
	end

	report({
		type = 'attest',
		decision = 'allow',
		level = 'info',
		reason = 'protected',
		target = tostring_(#result.installed) .. ' hooks',
	})
end)

if not ok then
	print_(('[torii] could not protect %s: %s'):format(resource, tostring_(err)))
	pcall_(report, {
		type = 'internal_error',
		decision = 'allow',
		level = 'warn',
		reason = 'init_failed',
		target = tostring_(err):sub(1, 120),
	})
end
