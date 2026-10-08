local dkjson = require('dkjson')
local policy = require('policy')
local url = require('url')

-- The CLI suggests these entries; the runtime must accept them and behave as the preset promises.

local function read_presets()
	local file = assert(io.open('cli/presets/known-resources.json', 'rb'))
	local text = file:read('a')
	file:close()
	return assert(dkjson.decode(text))
end

describe('known-library presets', function()
	local catalog = read_presets()

	it('only contain entries the runtime parser accepts', function()
		for _, preset in ipairs(catalog.presets) do
			for _, text in ipairs(preset.grants.http) do
				local entry, why = policy.parse_entry(text)
				assert.is_truthy(entry, preset.id .. ': ' .. text .. ' (' .. tostring(why) .. ')')
			end
		end
	end)

	it('let ox_lib reach the Overextended release API and nothing else on that host', function()
		local ox = {}
		for _, preset in ipairs(catalog.presets) do
			if preset.id == 'ox_lib' then
				ox = preset
			end
		end
		local lock =
			{ version = 1, resources = { ox_lib = { http = ox.grants.http, dynamic_code = ox.grants.dynamic_code } } }
		local p = policy.new(lock)
		assert.is_true(p:check_http('ox_lib', 'https://api.github.com/repos/overextended/ox_lib/releases/latest').allow)
		assert.is_true(
			p:check_http('ox_lib', 'https://api.github.com/repos/overextended/ox_inventory/releases/latest').allow
		)
		assert.is_false(p:check_http('ox_lib', 'https://api.github.com/repos/someone-else/x/releases/latest').allow)
		assert.is_false(p:check_http('ox_lib', 'https://api.github.com/repos/overextended-evil/x').allow)
		assert.is_false(p:check_http('ox_lib', 'https://api.github.com/users/overextended').allow)
		-- the rest of the account accepts issues and comments: a way to post data out
		assert.is_false(p:check_http('ox_lib', 'https://api.github.com/repos/overextended/ox_lib/issues').allow)
		assert.is_true(p:check_dynamic_code('ox_lib'))
	end)

	it('never suggest a bare shared host', function()
		for _, preset in ipairs(catalog.presets) do
			for _, text in ipairs(preset.grants.http) do
				local entry = assert(policy.parse_entry(text))
				if url.host_risk(entry.host) then
					assert.are_not.equal('/', entry.path, preset.id .. ' suggests ' .. text .. ' without a path prefix')
				end
			end
		end
	end)
end)
