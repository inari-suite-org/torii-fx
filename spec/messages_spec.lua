local messages = require('messages')

describe('messages', function()
	it('has every key in both languages, with the same placeholders', function()
		local function placeholders(text)
			local set = {}
			for name in text:gmatch('{(%w+)}') do
				set[name] = true
			end
			return set
		end
		for key, text in pairs(messages.en) do
			assert.is_string(messages.fr[key], 'missing in French: ' .. key)
			assert.are.same(placeholders(text), placeholders(messages.fr[key]), key)
		end
		for key in pairs(messages.fr) do
			assert.is_string(messages.en[key], 'missing in English: ' .. key)
		end
	end)

	it('fills placeholders and falls back to English, then to the key', function()
		assert.are.equal(
			'torii ne connaît pas a.example',
			messages.t('fr', 'why_unknown_host', { host = 'a.example' })
		)
		assert.are.equal('torii does not know a.example', messages.t('de', 'why_unknown_host', { host = 'a.example' }))
		assert.are.equal('no_such_key', messages.t('en', 'no_such_key'))
		assert.are.equal('torii does not know {host}', messages.t('en', 'why_unknown_host', {}))
		assert.are.equal('torii does not know 100%', messages.t('en', 'why_unknown_host', { host = '100%' }))
	end)

	it('reads the language convar', function()
		assert.are.equal('fr', messages.lang('fr'))
		assert.are.equal('fr', messages.lang('FR-fr'))
		assert.are.equal('en', messages.lang('en'))
		assert.are.equal('en', messages.lang(nil))
	end)

	it('has a why for every verdict code', function()
		local verdicts = require('verdicts')
		for _, target in ipairs({
			'https://45.133.1.20/',
			'https://xn--dscord-6ve.com/',
			'https://github.com.evil.example/',
			'https://dlscord.com/',
			'https://k8f3j2m9x7q1.example/',
			'https://pastebin.com/',
			'nope',
			'https://api.github.com/repos/overextended/ox_lib/releases/latest',
			'https://api.github.com/repos/someone/x/releases/latest',
			'https://discord.com/',
			'https://discord.com/api/webhooks/1',
			'https://api.telegram.org/x',
			'http://a.example/',
			'https://a.example/',
		}) do
			local code = verdicts.http(target).code
			assert.is_string(messages.en['why_' .. code], code)
		end
		assert.is_string(messages.en['why_' .. verdicts.dynamic(true).code])
		assert.is_string(messages.en['why_' .. verdicts.dynamic(false).code])
	end)
end)
