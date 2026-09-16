require_relative "../test_helper"

require "pathname"
require "rake"
require "tmpdir"

require "pro_tacts/store"

class BookTasksTest < Minitest::Test
  def test_naming_a_book_renames_its_group
    Dir.mktmpdir do |root|
      root = Pathname.new(root)
      ProTacts::Store.connect(root / "contacts.db") do |store|
        id = store.create_group(name: "sync:alpha@example.com")

        out, = run_task(root, "LOGIN" => "alpha@example.com", "NAME" => "Alpha Chen")

        assert_equal "alpha@example.com syncs sync:Alpha Chen\n", out
        assert_equal "sync:Alpha Chen", store.group(id).name
      end
    end
  end

  private

  # Runs book:name in a Rake application of its own, with root as the
  # data directory and env set for the run alone.
  def run_task(root, env)
    config = ProTacts.config
    application = Rake.application
    overridden = env.keys.to_h { [it, ENV.fetch(it, nil)] }

    ProTacts.config = ProTacts::Config.new("PRO_TACTS_DATA_DIR" => root.to_s)
    ENV.update(env)
    Rake.application = Rake::Application.new
    load (Pathname.new(__dir__).parent.parent / "tasks" / "book.rake").to_s
    capture_io { Rake.application["book:name"].invoke }
  ensure
    ProTacts.config = config
    Rake.application = application
    ENV.update(overridden)
  end
end
