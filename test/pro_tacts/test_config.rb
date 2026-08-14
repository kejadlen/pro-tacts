# frozen_string_literal: true

require "minitest/autorun"

require "pro_tacts/config"

class ConfigTest < Minitest::Test
  def test_sentry_dsn_is_passed_through
    assert_equal "https://example/1", ProTacts::Config.new("SENTRY_DSN" => "https://example/1").sentry_dsn
  end

  def test_sentry_dsn_is_required
    assert_raises(KeyError) { ProTacts::Config.new({}).sentry_dsn }
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
