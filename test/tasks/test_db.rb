require_relative "../test_helper"

require "open3"
require "pathname"
require "rake"
require "tmpdir"
require "yaml"

require "pro_tacts/store"
require "pro_tacts/vcard"

class DbTasksTest < Minitest::Test
  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"

  # The stored card as its bytes, and the three things beside it that no
  # card carries: the birthday, in a shape no client is sent, the group
  # with what it lends and who it lends to, and the name a login's book
  # goes by.
  def test_the_dump_writes_what_the_store_cannot_rebuild
    with_store do |store, root|
      store.put("aiden", vcard(AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04\r\nEND:VCARD\r\n")))
      group = store.create_group(name: "Booles")
      store.set_group_lines(group, ["NOTE:a household"])
      store.add_member(group, "aiden")
      store.name_book("alpha@example.com", "Alpha Chen")

      dump(root)

      assert_equal AIDEN, (root / "dump" / "cards" / "aiden.vcf").binread
      assert_equal({"aiden" => {"year" => 1985, "month" => 4}}, YAML.safe_load((root / "dump" / "birthdays.yml").read))
      assert_equal({"name" => "Booles", "lines" => ["NOTE:a household"], "members" => ["aiden"]},
        YAML.safe_load((root / "dump" / "groups" / "#{group}.yml").read))
      assert_equal({"alpha@example.com" => "Alpha Chen"}, YAML.safe_load((root / "dump" / "books.yml").read))
    end
  end

  # A deployment that has named no book still gets the file, so the
  # dump says there are none rather than leaving it to a missing file.
  def test_a_store_that_has_named_no_book_dumps_the_file_anyway
    with_store do |store, root|
      store.put("aiden", vcard(AIDEN))

      dump(root)

      assert_equal({}, YAML.safe_load((root / "dump" / "books.yml").read))
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

  # The dump is a repository of its own, so the snapshot a console
  # session starts from can be reverted to
  # (docs/plans/2026-09-20-the-dump-commits.md).
  def test_the_dump_commits_what_it_wrote
    with_store do |store, root|
      store.put("aiden", vcard(AIDEN))

      dump(root)

      assert_includes tracked(root / "dump"), "cards/aiden.vcf"
      assert_equal 1, subjects(root / "dump").size
      assert_match(/\Adump \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, subjects(root / "dump").first)
    end
  end

  # History is the writes rather than the runs, so dumping again over an
  # unchanged store says nothing.
  def test_a_dump_that_moved_nothing_adds_no_commit
    with_store do |store, root|
      store.put("aiden", vcard(AIDEN))
      dump(root)

      dump(root)

      assert_equal 1, subjects(root / "dump").size
    end
  end

  # What left the store leaves the repository too, rather than staying
  # tracked at the revision it was deleted in.
  def test_the_commit_drops_what_left_the_store
    with_store do |store, root|
      store.put("aiden", vcard(AIDEN))
      dump(root)
      store.delete("aiden")

      dump(root)

      refute_includes tracked(root / "dump"), "cards/aiden.vcf"
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
    capture_subprocess_io { Rake.application["db:dump"].invoke }
  ensure
    ProTacts.config = config
    Rake.application = application
    ENV["DUMP"] = overridden
  end

  def tracked(dump) = git(dump, "ls-files")

  def subjects(dump) = git(dump, "log", "--format=%s")

  def git(dump, *arguments)
    out, error, status = Open3.capture3("git", "-C", dump.to_s, *arguments)
    raise error unless status.success?
    out.lines(chomp: true)
  end
end
