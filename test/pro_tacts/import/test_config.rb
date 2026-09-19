require_relative "../../test_helper"

require "pathname"
require "tmpdir"

require "pro_tacts/import/config"

class ImportConfigTest < Minitest::Test
  Config = ProTacts::Import::Config

  def test_a_missing_file_is_no_configuration
    Dir.mktmpdir do |dir|
      assert_equal({}, Config.read(Pathname.new(dir) / "config.yml"))
    end
  end

  def test_an_empty_file_is_no_configuration
    with_config_file("") do |path|
      assert_equal({}, Config.read(path))
    end
  end

  def test_the_mapping_is_read
    with_config_file("host: https://contacts\n") do |path|
      assert_equal({"host" => "https://contacts"}, Config.read(path))
    end
  end

  def test_a_file_whose_top_level_is_not_a_mapping_is_refused
    with_config_file("- one\n- two\n") do |path|
      error = assert_raises(ArgumentError) { Config.read(path) }

      assert_equal "#{path} is not a YAML mapping", error.message
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
