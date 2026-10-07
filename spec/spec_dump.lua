-- Test helper: flattens a value (recursively) into one string so specs can assert that a secret
-- never appears anywhere in the data torii reported.
local function dump(value, out)
	out = out or {}
	if type(value) == 'table' then
		for k, v in pairs(value) do
			dump(k, out)
			dump(v, out)
		end
	else
		out[#out + 1] = tostring(value)
	end
	return out
end

return function(value)
	return table.concat(dump(value), '\n')
end
