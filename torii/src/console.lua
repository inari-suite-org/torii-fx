-- Text for the "torii" console command (read-only): status, review, explain. Pure functions returning lines, so that
-- they can be tested; the core prints them. Fields that come from resources (names, targets, call sites) lose the
-- FiveM colour codes (^0-^9), so a resource cannot dress its own line up as a torii verdict.

local req = type((...)) == 'function' and (...) or require
local messages = req('messages')

local M = {}

local PREFIX = '^3[torii]^7 '

local function clean(value)
	return (tostring(value or ''):gsub('%^', ''))
end

local function when(t)
	return type(t) == 'number' and os.date('!%Y-%m-%d %H:%M UTC', t) or '?'
end

local function verdict_text(lang, verdict)
	local why = messages.t(
		lang,
		'why_' .. verdict.code,
		setmetatable({}, {
			__index = function(_, name)
				local value = verdict.params[name]
				return value ~= nil and clean(value) or nil
			end,
		})
	)
	local todo
	if verdict.level == 'suspicious' then
		todo = messages.t(lang, 'todo_suspicious')
	elseif verdict.level == 'common' and not verdict.weak then
		todo = messages.t(lang, 'todo_common')
	else
		todo = messages.t(lang, 'todo_' .. verdict.code, { host = clean(verdict.params.host) })
	end
	return why, todo
end

local function describe(lang, item)
	if item.kind == 'http' then
		return messages.t(lang, 'item_http', { resource = clean(item.resource), target = clean(item.target) })
	end
	local origin = messages.t(lang, item.from_memory and 'origin_memory' or 'origin_files')
	return messages.t(lang, 'item_dynamic', { resource = clean(item.resource), origin = origin })
end

--- Status: the summary line and the readiness line.
function M.status(review, lang, mode)
	local total, suspicious = review:counts()
	local lines = {}
	if total == 0 then
		lines[1] = PREFIX .. messages.t(lang, 'summary_none')
	else
		lines[1] = PREFIX .. messages.t(lang, 'summary_some', { count = total, suspicious = suspicious })
	end
	local key, vars = review:readiness(mode)
	lines[2] = PREFIX .. messages.t(lang, key, vars)
	if review.overflow > 0 then
		lines[3] = PREFIX .. ('(+%d)'):format(review.overflow)
	end
	return lines
end

--- Review: one numbered row per request, worst first, with why and what to do.
function M.review(review, lang)
	local rows = review:list()
	if #rows == 0 then
		return { PREFIX .. messages.t(lang, 'review_empty') }
	end
	local lines = { PREFIX .. messages.t(lang, 'review_header', { count = #rows, days = review:days() }), '' }
	for _, row in ipairs(rows) do
		local why, todo = verdict_text(lang, row.verdict)
		lines[#lines + 1] = ('  %2d  %s  %s'):format(
			row.n,
			messages.t(lang, 'level_' .. row.verdict.level),
			describe(lang, row.item)
		)
		lines[#lines + 1] = ('        %s: %s'):format(messages.t(lang, 'why'), why)
		lines[#lines + 1] = ('        %s: %s'):format(messages.t(lang, 'todo'), todo)
		if row.loader then
			lines[#lines + 1] = ('        %s %s'):format(
				messages.t(lang, 'level_suspicious'),
				messages.t(lang, 'loader_shape')
			)
		end
	end
	lines[#lines + 1] = ''
	lines[#lines + 1] = PREFIX .. messages.t(lang, 'review_footer')
	return lines
end

--- Explain: everything torii knows about request `n`.
function M.explain(review, lang, n)
	local wanted = tonumber(n)
	for _, row in ipairs(review:list()) do
		if row.n == wanted then
			local why, todo = verdict_text(lang, row.verdict)
			local lines = {
				('%s%d  %s  %s'):format(
					PREFIX,
					row.n,
					messages.t(lang, 'level_' .. row.verdict.level),
					describe(lang, row.item)
				),
				'    ' .. messages.t(
					lang,
					'explain_seen',
					{ count = row.item.count, first = when(row.item.first), last = when(row.item.last) }
				),
			}
			if row.item.src then
				lines[#lines + 1] = '    ' .. messages.t(lang, 'explain_at', { src = clean(row.item.src) })
			end
			lines[#lines + 1] = ('    %s: %s'):format(messages.t(lang, 'why'), why)
			lines[#lines + 1] = ('    %s: %s'):format(messages.t(lang, 'todo'), todo)
			return lines
		end
	end
	return { PREFIX .. messages.t(lang, 'explain_unknown', { n = clean(n) }) }
end

function M.help(lang)
	return { PREFIX .. messages.t(lang, 'help') }
end

return M
