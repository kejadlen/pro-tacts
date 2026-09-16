# config.ru for `rake dev`, which has no proxy in front of it to write
# the login (ProTacts::DevLogin). Deployments run config.ru alone.
require "pathname"

$LOAD_PATH.unshift(Pathname.new(__dir__) / "lib")
require "pro_tacts/dev_login"

use ProTacts::DevLogin
run Rack::Builder.parse_file(File.expand_path("config.ru", __dir__))
