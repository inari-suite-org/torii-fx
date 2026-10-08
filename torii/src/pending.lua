-- Requests waiting for the admin's decision: what resources tried to do without a grant, grouped, with a verdict.
-- Fed by the core with sanitised log events; read by the "torii review" console command. It only describes: granting
-- stays with the admin and the lockfile. The state survives restarts (the core saves it in torii's own folder, which
-- other resources cannot write) so that "observing for N days" and the weekend check mean something.

local req = type((...)) == 'function' and (...) or require
local verdicts = req('verdicts')

local M = {}
M.__index = M

M.MIN_DAYS = 3
M.MAX_ITEMS = 300
M.MAX_PER_RESOURCE = 25

-- Only what a lockfile line can fix. Private addresses, bytecode and the like are refused whatever the admin says.
local APPROVABLE = {
	resource_not_in_lockfile = true,
	not_in_allow_list = true,
	dynamic_code_not_granted = true,
	text_not_from_resource_files = true,
}

local function is_weekend(now)
	local wday = os.date('*t', now).wday
	return wday == 1 or wday == 7
end

---@param opts { now: fun(): integer }|nil
function M.new(opts)
	opts = opts or {}
	local self = setmetatable({
		now = opts.now or os.time,
		since = nil, -- when observe mode was first seen
		weekend = false, -- a weekend day was seen while observing
		items = {},
		order = {}, -- keys, in first-seen order
		per_resource = {},
		overflow = 0,
		dirty = false,
	}, M)
	return self
end

--- Called regularly with the current mode: tracks how long torii has been observing.
function M:tick(mode)
	local now = self.now()
	if mode ~= 'observe' then
		return
	end
	if not self.since then
		self.since = now
		self.dirty = true
	end
	if not self.weekend and is_weekend(now) then
		self.weekend = true
		self.dirty = true
	end
end

local function key_of(resource, kind, target)
	return resource .. '\0' .. kind .. '\0' .. target
end

--- Feeds one sanitised event (as written to the log). Returns true when it added or updated an item.
function M:observe(event)
	if type(event) ~= 'table' or event.resource == 'torii' then
		return false
	end
	if event.decision ~= 'would_deny' and event.decision ~= 'deny' then
		return false
	end
	if not APPROVABLE[event.reason] then
		return false
	end
	local kind, target
	if event.type == 'http' then
		local t = verdicts.split_target(event.target)
		if not t then
			return false
		end
		kind = 'http'
		local host = t.kind == 'ipv6' and ('[' .. t.host .. ']') or t.host
		target = t.scheme .. '://' .. host .. t.port .. (t.path == '/' and '' or t.path)
	elseif event.type == 'dynamic_code' then
		kind, target = 'dynamic', 'load'
	else
		return false
	end
	local resource = tostring(event.resource)
	local key = key_of(resource, kind, target)
	local now = self.now()
	local item = self.items[key]
	if not item then
		if #self.order >= M.MAX_ITEMS or (self.per_resource[resource] or 0) >= M.MAX_PER_RESOURCE then
			self.overflow = self.overflow + 1
			return false
		end
		item = { resource = resource, kind = kind, target = target, count = 0, first = now, from_memory = false }
		self.items[key] = item
		self.order[#self.order + 1] = key
		self.per_resource[resource] = (self.per_resource[resource] or 0) + 1
	end
	item.count = item.count + 1
	item.last = now
	item.src = type(event.src) == 'string' and event.src or item.src
	if kind == 'dynamic' and event.origin ~= 'files' then
		item.from_memory = true
	end
	self.dirty = true
	return true
end

--- Drops what the current lockfile now allows (after the admin approved it and restarted).
---@param policy table a policy.lua Policy
function M:refresh(policy)
	local kept = {}
	for _, key in ipairs(self.order) do
		local item = self.items[key]
		local allowed
		if item.kind == 'http' then
			local ok, decision = pcall(policy.check_http, policy, item.resource, item.target)
			allowed = ok and decision.allow
		else
			local ok, allow = pcall(policy.check_dynamic_code, policy, item.resource, not item.from_memory)
			allowed = ok and allow
		end
		if allowed then
			self.items[key] = nil
			self.per_resource[item.resource] = (self.per_resource[item.resource] or 1) - 1
			self.dirty = true
		else
			kept[#kept + 1] = key
		end
	end
	self.order = kept
end

--- The review: items with their verdicts, worst resources first, numbered from 1.
---@return { n: integer, item: table, verdict: table, resource_level: string, loader: boolean }[]
function M:list()
	local by_resource, names = {}, {}
	for _, key in ipairs(self.order) do
		local item = self.items[key]
		local group = by_resource[item.resource]
		if not group then
			group = { http = {}, dynamic = nil, entries = {} }
			by_resource[item.resource] = group
			names[#names + 1] = item.resource
		end
		local verdict = item.kind == 'http' and verdicts.http(item.target) or verdicts.dynamic(item.from_memory)
		if item.kind == 'http' then
			group.http[#group.http + 1] = verdict
		else
			group.dynamic = verdict
		end
		group.entries[#group.entries + 1] = { item = item, verdict = verdict }
	end
	for _, name in ipairs(names) do
		local group = by_resource[name]
		group.level = verdicts.worst(group.http, group.dynamic)
		group.loader = verdicts.loader_shape(group.http, group.dynamic)
	end
	table.sort(names, function(a, b)
		local la, lb = verdicts.LEVELS[by_resource[a].level], verdicts.LEVELS[by_resource[b].level]
		if la ~= lb then
			return la > lb
		end
		return a < b
	end)
	local out = {}
	for _, name in ipairs(names) do
		local group = by_resource[name]
		table.sort(group.entries, function(a, b)
			local la, lb = verdicts.LEVELS[a.verdict.level], verdicts.LEVELS[b.verdict.level]
			if la ~= lb then
				return la > lb
			end
			return a.item.target < b.item.target
		end)
		for i, entry in ipairs(group.entries) do
			out[#out + 1] = {
				n = #out + 1,
				item = entry.item,
				verdict = entry.verdict,
				resource_level = group.level,
				loader = group.loader and i == #group.entries, -- shown once, after the resource's last item
			}
		end
	end
	return out
end

--- Number of items, and how many resources look suspicious (an item of theirs, or the loader shape).
function M:counts()
	local total, suspicious, seen = 0, 0, {}
	for _, row in ipairs(self:list()) do
		total = total + 1
		if row.resource_level == 'suspicious' and not seen[row.item.resource] then
			seen[row.item.resource] = true
			suspicious = suspicious + 1
		end
	end
	return total, suspicious
end

function M:days()
	if not self.since then
		return 0
	end
	return math.max(0, (self.now() - self.since) // 86400)
end

--- Whether enforce mode looks safe to switch on: a message key and its placeholders.
function M:readiness(mode)
	if mode == 'enforce' then
		return 'mode_enforce', {}
	end
	local total = self:counts()
	if total > 0 then
		return 'not_ready_pending', { count = total }
	end
	local days = self:days()
	if days < M.MIN_DAYS then
		return 'not_ready_days', { days = days, min = M.MIN_DAYS }
	end
	if not self.weekend then
		return 'not_ready_weekend', {}
	end
	return 'ready_enforce', { days = days }
end

--- Plain table for json.encode.
function M:export()
	local items = {}
	for _, key in ipairs(self.order) do
		items[#items + 1] = self.items[key]
	end
	return { version = 1, since = self.since, weekend = self.weekend, items = items }
end

--- Restores a saved state. Anything malformed is skipped: the file is torii's own, but it can be damaged.
function M:import(saved)
	if type(saved) ~= 'table' or saved.version ~= 1 then
		return
	end
	if math.type(saved.since) == 'integer' or type(saved.since) == 'number' then
		self.since = math.floor(saved.since)
	end
	self.weekend = saved.weekend == true
	if type(saved.items) ~= 'table' then
		return
	end
	for _, item in ipairs(saved.items) do
		if
			type(item) == 'table'
			and type(item.resource) == 'string'
			and (item.kind == 'http' or item.kind == 'dynamic')
			and type(item.target) == 'string'
			and type(item.count) == 'number'
			and #self.order < M.MAX_ITEMS
		then
			local key = key_of(item.resource, item.kind, item.target)
			if not self.items[key] then
				self.items[key] = {
					resource = item.resource,
					kind = item.kind,
					target = item.target,
					count = math.floor(item.count),
					first = tonumber(item.first),
					last = tonumber(item.last),
					src = type(item.src) == 'string' and item.src or nil,
					from_memory = item.from_memory == true,
				}
				self.order[#self.order + 1] = key
				self.per_resource[item.resource] = (self.per_resource[item.resource] or 0) + 1
			end
		end
	end
end

return M
