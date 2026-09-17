require_relative "../../test_helper"

require "json"
require "pathname"
require "tmpdir"

require "pro_tacts/import/plan"

class ImportPlanTest < Minitest::Test
  include ThrowawayContacts

  Plan = ProTacts::Import::Plan

  CREATED_AT = Time.utc(2026, 9, 16, 18, 4, 12)

  def entry(id, source_id: "#{id}:ABPerson", backup: {"original.vcf" => "BEGIN:VCARD\r\n"})
    Plan::Entry.new(id:, source_id:, card: card(id, "Ada Lovelace"), backup:)
  end

  def in_tmpdir
    Dir.mktmpdir { yield Pathname.new(it) / "plan" }
  end

  def test_a_written_plan_reads_back
    in_tmpdir do |dir|
      Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru"), entry("vmnlryyvktux")])

      plan = Plan.read(dir)

      assert_equal "macos", plan.source
      assert_equal "2026-09-16T18:04:12Z", plan.created_at
      assert_equal [Plan::Contact.new(id: "kmnuqmzxylru", source_id: "kmnuqmzxylru:ABPerson", status: nil), Plan::Contact.new(id: "vmnlryyvktux", source_id: "vmnlryyvktux:ABPerson", status: nil)], plan.contacts
      assert_equal card("kmnuqmzxylru", "Ada Lovelace"), plan.card("kmnuqmzxylru")
      assert_nil plan.host
      assert_nil plan.group_id
    end
  end

  def test_the_group_is_named_for_when_the_plan_was_built
    in_tmpdir do |dir|
      Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [])

      assert_equal "import-20260916T180412Z", Plan.read(dir).group
    end
  end

  def test_the_backup_is_written_as_given
    in_tmpdir do |dir|
      photo = "\xFF\xD8\xFF".b
      Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru", backup: {"original.vcf" => "BEGIN:VCARD\r\n", "photo.jpg" => photo})])

      assert_equal "BEGIN:VCARD\r\n", (dir / "backups/kmnuqmzxylru/original.vcf").read
      assert_equal photo, (dir / "backups/kmnuqmzxylru/photo.jpg").binread
    end
  end

  def test_a_plan_is_never_written_over_another
    in_tmpdir do |dir|
      Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru")])

      assert_raises(Errno::EEXIST) { Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: []) }
      assert_equal ["kmnuqmzxylru"], Plan.read(dir).contacts.map(&:id)
    end
  end

  def test_progress_is_saved_into_the_plan_as_it_is_recorded
    in_tmpdir do |dir|
      plan = Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru"), entry("vmnlryyvktux")])

      plan.host = "https://contacts"
      plan.record("kmnuqmzxylru", "landed")
      plan.group_id = "kxsv"

      read = Plan.read(dir)
      assert_equal "https://contacts", read.host
      assert_equal "kxsv", read.group_id
      assert_equal ["landed", nil], read.contacts.map(&:status)
      assert_equal ["plan.json"], dir.children.map { it.basename.to_s }.grep(/plan/)
    end
  end
end
