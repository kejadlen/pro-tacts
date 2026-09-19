require_relative "../../test_helper"

require "pathname"
require "tmpdir"

require "pro_tacts/import/config"

class ImportConfigTest < Minitest::Test
  Config = ProTacts::Import::Config

  def test_the_mapping_is_read
    with_config_file("host: https://contacts\n") do |path|
      assert_equal Config.new(host: "https://contacts"), Config.read(path)
    end
  end

  def test_a_missing_file_is_refused
    Dir.mktmpdir do |dir|
      error = assert_raises(ArgumentError) { Config.read(Pathname.new(dir) / "config.yml") }

      assert_equal "#{Pathname.new(dir) / "config.yml"}: does not exist", error.message
    end
  end

  def test_an_empty_file_has_no_host
    with_config_file("") do |path|
      error = assert_raises(ArgumentError) { Config.read(path) }

      assert_equal "#{path}: has no host", error.message
    end
  end

  def test_a_file_whose_top_level_is_not_a_mapping_is_refused
    with_config_file("- one\n- two\n") do |path|
      error = assert_raises(ArgumentError) { Config.read(path) }

      assert_equal "#{path}: is not a mapping", error.message
    end
  end

  def test_a_key_no_member_takes_is_refused
    with_config_file("hots: contacts\n") do |path|
      error = assert_raises(ArgumentError) { Config.read(path) }

      assert_equal "#{path}: has hots, which no member takes", error.message
    end
  end

  def test_a_host_that_is_not_text_is_refused
    with_config_file("host: 9292\n") do |path|
      error = assert_raises(ArgumentError) { Config.read(path) }

      assert_equal "#{path}: host must be text", error.message
    end
  end

  def test_a_blank_host_is_refused
    with_config_file("host: \"\"\n") do |path|
      error = assert_raises(ArgumentError) { Config.read(path) }

      assert_equal "#{path}: host is blank", error.message
    end
  end

  private

  #: (String content) { (Pathname) -> void } -> void
  def with_config_file(content)
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "config.yml"
      path.write(content)

      yield path
    end
  end
end
