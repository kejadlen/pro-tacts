require "test_helper"

require "tmpdir"

class ProTactsTest < Minitest::Test
  def teardown
    # Reset the swapped-in config so later tests see the default one.
    ProTacts.config = nil
  end

  def test_ensure_data_directories_creates_a_nested_contacts_dir
    Dir.mktmpdir do |tmp|
      data_dir = File.join(tmp, "nested", "data")
      ProTacts.config = ProTacts::Config.new("PRO_TACTS_DATA_DIR" => data_dir)

      ProTacts.ensure_data_directories

      assert_path_exists File.join(data_dir, "contacts")
    end
  end

  def test_ensure_data_directories_is_idempotent
    Dir.mktmpdir do |tmp|
      data_dir = File.join(tmp, "data")
      ProTacts.config = ProTacts::Config.new("PRO_TACTS_DATA_DIR" => data_dir)

      2.times { ProTacts.ensure_data_directories }

      assert_path_exists File.join(data_dir, "contacts")
    end
  end
end
