local sha256 = require('sha256')

describe('sha256', function()
	it('matches the NIST test vectors', function()
		assert.are.equal('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', sha256.hex(''))
		assert.are.equal('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', sha256.hex('abc'))
		assert.are.equal(
			'248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
			sha256.hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')
		)
	end)

	it('agrees with an independent implementation around the block boundary', function()
		-- Expected values were produced with Python hashlib.
		local expected = {
			[55] = '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
			[56] = 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
			[64] = 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
		}
		for length, digest in pairs(expected) do
			assert.are.equal(digest, sha256.hex(string.rep('a', length)), 'length ' .. length)
		end
	end)

	it('hashes a million bytes like the reference', function()
		assert.are.equal(
			'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
			sha256.hex(string.rep('a', 1000000))
		)
	end)
end)
