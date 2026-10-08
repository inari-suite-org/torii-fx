RegisterCommand('exp11_call_js', () => {
  console.log('[exp11] js caller: direct');
  ExecuteCommand('exp11_secure from-js');
  ExecuteCommand('exp11_open from-js');
  console.log('[exp11] js caller: done');
}, true);
console.log('[exp11] js caller ready: type "exp11_call_js"');
