
require "pathname"

$LOAD_PATH.unshift(Pathname.new(__dir__) / "lib")
require "pro_tacts/web"

ProTacts.ensure_data_directories

run ProTacts::Web.freeze.app
