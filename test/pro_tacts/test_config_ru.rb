require "test_helper"

# Rack reads config.ru with the process's default external encoding,
# which is US-ASCII under a C locale; any non-ASCII byte in the file
# crashes boot (seen with rack 3.2.4). Ordinary .rb files are safe
# because Ruby parses source as UTF-8 regardless of locale.
class ConfigRuTest < Minitest::Test
  def test_config_ru_is_ascii_only
    config_ru = File.expand_path("../../config.ru", __dir__)

    assert File.read(config_ru).ascii_only?,
           "config.ru must stay ASCII-only or boot crashes under a C locale"
  end
end
