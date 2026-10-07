EXP01_ORDER = EXP01_ORDER or {}
EXP01_ORDER[#EXP01_ORDER + 1] = 'server'
print('[exp01] consumer started. load order = ' .. table.concat(EXP01_ORDER, ' > '))
