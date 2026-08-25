
require "minitest/autorun"

require "pro_tacts/config"

class ConfigTest < Minitest::Test
  def test_sentry_dsn_is_passed_through
    assert_equal "https://example/1", ProTacts::Config.new("SENTRY_DSN" => "https://example/1").sentry_dsn
  end

  def test_sentry_dsn_is_nil_when_unset
    assert_nil ProTacts::Config.new({}).sentry_dsn
    assert_nil ProTacts::Config.new("SENTRY_DSN" => nil).sentry_dsn
  end

  def test_data_dir_defaults_to_data
    assert_equal Pathname.new("data"), ProTacts::Config.new({}).data_dir
  end

  def test_data_dir_is_overridable
    assert_equal Pathname.new("/tmp/state"), ProTacts::Config.new("PRO_TACTS_DATA_DIR" => "/tmp/state").data_dir
  end

  def test_the_database_lives_under_the_data_dir
    assert_equal Pathname.new("data/contacts.db"), ProTacts::Config.new({}).database_path
    assert_equal Pathname.new("/tmp/state/contacts.db"), ProTacts::Config.new("PRO_TACTS_DATA_DIR" => "/tmp/state").database_path
  end

  def test_the_database_path_is_overridable_on_its_own
    config = ProTacts::Config.new("PRO_TACTS_DATA_DIR" => "/tmp/state", "PRO_TACTS_DATABASE" => "/srv/cards.db")

    assert_equal Pathname.new("/srv/cards.db"), config.database_path
    assert_equal Pathname.new("/tmp/state"), config.data_dir
  end

  def test_debug_defaults_off
    refute ProTacts::Config.new({}).debug?
    refute ProTacts::Config.new("PRO_TACTS_DEBUG" => nil).debug?
  end

  def test_debug_turns_on_for_truthy_values
    assert ProTacts::Config.new("PRO_TACTS_DEBUG" => "1").debug?
    assert ProTacts::Config.new("PRO_TACTS_DEBUG" => "true").debug?
    assert ProTacts::Config.new("PRO_TACTS_DEBUG" => "YES").debug?
  end

  def test_debug_ignores_other_values
    refute ProTacts::Config.new("PRO_TACTS_DEBUG" => "no").debug?
    refute ProTacts::Config.new("PRO_TACTS_DEBUG" => "0").debug?
  end

  def test_debug_log_path_defaults_to_a_file
    assert_equal "log/debug.log", ProTacts::Config.new({}).debug_log_path
  end

  def test_debug_log_path_is_overridable
    assert_equal "/tmp/dav.log", ProTacts::Config.new("PRO_TACTS_DEBUG_LOG" => "/tmp/dav.log").debug_log_path
    assert_equal "stderr", ProTacts::Config.new("PRO_TACTS_DEBUG_LOG" => "stderr").debug_log_path
  end
end
