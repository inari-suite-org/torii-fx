-- Usage: exp07_read <path>   Prints only whether the open worked and whether the file starts with "CANARY".
-- Never prints file contents. Use harmless canary files only.
RegisterCommand('exp07_read', function(_, args)
	local path = args[1]
	if not path then print('[exp07] usage: exp07_read <path>') return end
	local f, err, code = io.open(path, 'rb')
	if not f then
		print(('[exp07] %s -> open FAILED (%s, code %s)'):format(path, tostring(err), tostring(code)))
		return
	end
	local head = f:read(6)
	f:close()
	print(('[exp07] %s -> open OK, starts with CANARY: %s'):format(path, tostring(head == 'CANARY')))
end, true)
print('[exp07] ready, run: exp07_read <path>')
