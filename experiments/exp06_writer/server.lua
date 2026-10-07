RegisterCommand('exp06_write', function()
	local own = SaveResourceFile(GetCurrentResourceName(), 'own.txt', 'x', -1)
	local cross = SaveResourceFile('exp06_target', 'from_writer_native.txt', 'x', -1)
	local f = io.open('@exp06_target/from_writer_io.txt', 'w')
	local ioOk = f ~= nil
	if f then f:write('x'); f:close() end
	print(('[exp06] SaveResourceFile own=%s | SaveResourceFile cross=%s | io.open cross write=%s'):format(
		tostring(own), tostring(cross), tostring(ioOk)))
end, true)
print('[exp06] writer ready, run: exp06_write')
