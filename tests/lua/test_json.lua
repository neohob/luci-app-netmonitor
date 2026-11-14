-- F12: empty array/object encoding footgun.
local H = require 'helper'
local json = require 'netmonitor.json'

H.case('W21', 'json empty array vs object + round-trip', function()
	H.eq(json.encode(json.array()), '[]', 'empty array')
	H.eq(json.encode(json.object()), '{}', 'empty object')
	H.eq(json.encode({}), '[]', 'bare empty table = array')
	local obj = json.object({ a = 1, warnings = json.array() })
	local enc = json.encode(obj)
	H.ok(enc:find('"warnings":%[%]'), 'nested empty array: ' .. enc)
	H.ok(not enc:find('"warnings":{}'), 'warnings not object')
	local back = assert(json.decode(enc))
	H.eq(back.a, 1, 'round-trip a')
	H.eq(#back.warnings, 0, 'round-trip warnings')
	local arr = json.decode('[1,2,{"x":true}]')
	H.eq(#arr, 3, 'array len')
	H.eq(arr[3].x, true, 'nested object')
	H.eq(json.encode(json.decode('{"warnings":[]}')), '{"warnings":[]}', 'object with empty array')
end)
