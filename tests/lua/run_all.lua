package.path = './tests/lua/?.lua;' .. package.path
local H = require 'helper'

require 'test_package'
require 'test_storage'
require 'test_collector'
require 'test_api'
require 'test_json'
require 'test_sni'

if not H.summary() then os.exit(1) end
