package.path = './tests/lua/?.lua;' .. package.path
local H = require 'helper'

require 'test_package'
require 'test_storage'
require 'test_collector'
require 'test_api'
require 'test_json'
require 'test_sni'
require 'test_asn'
require 'test_service'
require 'test_timeutil'
require 'test_rollup'
require 'test_monthly_api'
require 'test_monthly_ui'

if not H.summary() then os.exit(1) end

