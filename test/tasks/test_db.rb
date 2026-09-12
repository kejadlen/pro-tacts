require_relative "../test_helper"

require "pathname"
require "rake"
require "tmpdir"
require "yaml"

require "pro_tacts/store"
require "pro_tacts/vcard"

class DbTasksTest < Minitest::Test
  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"

  # The stored card as its bytes, and the two things beside it that no
  # card carries: the birthday, in a shape no client is sent, and the
  # group with what it lends and who it lends to.
  def test_the_dump_writes_what_the_store_cannot_rebuild
    with_store do |store, root|
      store.put("aiden", vcard(AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04\r\nEND:VCARD\r\n")))
      group = store.create_group(name: "Booles")
      store.set_group_lines(group, ["NOTE:a household"])
      store.add_member(group, "aiden")

      dump(root)

      assert_equal AIDEN, (root / "dump" / "cards" / "aiden.vcf").binread
      assert_equal({"aiden" => {"year" => 1985, "month" => 4}}, YAML.safe_load((root / "dump" / "birthdays.yml").read))
      assert_equal({"name" => "Booles", "lines" => ["NOTE:a household"], "members" => ["aiden"]},
        YAML.safe_load((root / "dump" / "groups" / "#{group}.yml").read))
    end
  end

  # A dump over a dump matches the store: a card gone from it is gone
  # from the directory, and what the dump does not write is left alone.
  def test_a_dump_over_a_dump_drops_what_left_the_store
    with_store do |store, root|
      store.put("aiden", vcard(AIDEN))
      (root / "dump" / "cards").mkpath
      (root / "dump" / "cards" / "gone.vcf").write("stale")
      (root / "dump" / "README").write("mine")

      dump(root)

      assert_equal ["aiden.vcf"], (root / "dump" / "cards").children.map { it.basename.to_s }
      assert_equal "mine", (root / "dump" / "README").read
    end
  end

  private

  def with_store
    Dir.mktmpdir do |root|
      root = Pathname.new(root)
      ProTacts::Store.connect(root / "contacts.db") { |store| yield store, root }
    end
  end

  def vcard(bytes) = ProTacts::VCard.new(bytes)

  # Runs db:dump in a Rake application of its own, configured with root
  # as the data directory, so the database is root's and the default
  # dump lands in root/dump.
  def dump(root)
    config = ProTacts.config
    application = Rake.application
    overridden = ENV.delete("DUMP")

    ProTacts.config = ProTacts::Config.new("PRO_TACTS_DATA_DIR" => root.to_s)
    Rake.application = Rake::Application.new
    load (Pathname.new(__dir__).parent.parent / "tasks" / "db.rake").to_s
    capture_io { Rake.application["db:dump"].invoke }
  ensure
    ProTacts.config = config
    Rake.application = application
    ENV["DUMP"] = overridden
  end
end
