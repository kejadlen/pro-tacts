require_relative "../../test_helper"

require "pathname"
require "tmpdir"

require "pro_tacts/import/plan"

class ImportPlanTest < Minitest::Test
  include ThrowawayContacts

  Plan = ProTacts::Import::Plan

  CREATED_AT = Time.utc(2026, 9, 16, 18, 4, 12)

  SOURCE = {"identifier" => "A:ABPerson", "vcard" => "BEGIN:VCARD\r\nEND:VCARD\r\n", "note" => nil, "contact" => {}}
  ADA = ProTacts::Import::Card.new(first: "Ada", last: "Lovelace", nickname: nil, birthday: nil, phones: [{"number" => "+12532189075"}], emails: [], addresses: [], note: nil, photo: false, groups: [], source: SOURCE)

  def entry(id, source_id: "#{id}:ABPerson", card: ADA)
    Plan::Entry.new(id:, source_id:, card:)
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
      assert_equal [Plan::Contact.new(id: "kmnuqmzxylru", source_id: "kmnuqmzxylru:ABPerson", name: "Ada Lovelace", status: nil), Plan::Contact.new(id: "vmnlryyvktux", source_id: "vmnlryyvktux:ABPerson", name: "Ada Lovelace", status: nil)], plan.contacts
    end
  end

  def test_a_contact_with_one_name_is_listed_under_it
    in_tmpdir do |dir|
      card = ProTacts::Import::Card.new(first: "Mitch", last: "", nickname: nil, birthday: nil, phones: [], emails: [], addresses: [], note: nil, photo: false, groups: [], source: SOURCE)

      Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru", card:)])

      assert_equal ["Mitch"], Plan.read(dir).contacts.map(&:name)
    end
  end

  def test_the_group_is_named_for_when_the_plan_was_built
    in_tmpdir do |dir|
      Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [])

      assert_equal "import-20260916T180412Z", Plan.read(dir).group
    end
  end

  def test_a_card_joins_everyone_and_the_plans_group_after_its_own
    in_tmpdir do |dir|
      card = ADA.with(groups: ["family"])
      Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru", card:)])

      assert_equal <<~YAML, (dir / "cards/kmnuqmzxylru.yml").read
        ---
        first: Ada
        last: Lovelace
        nickname:
        birthday:
        phones:
        - number: "+12532189075"
        emails: []
        addresses: []
        note:
        photo: false
        groups:
        - sync:*
        - import-20260916T180412Z
        - family
        source:
          identifier: A:ABPerson
          vcard: "BEGIN:VCARD\\r\\nEND:VCARD\\r\\n"
          note:
          contact: {}
      YAML
    end
  end

  def test_a_card_reads_back_with_its_edits
    in_tmpdir do |dir|
      plan = Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru")])
      path = dir / "cards/kmnuqmzxylru.yml"
      path.write(path.read.sub("first: Ada", "first: Augusta Ada"))

      assert_equal "Augusta Ada", plan.card("kmnuqmzxylru").first
    end
  end

  def test_a_plan_is_never_written_over_another
    in_tmpdir do |dir|
      Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru")])

      assert_raises(Errno::EEXIST) { Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: []) }
      assert_equal ["kmnuqmzxylru"], Plan.read(dir).contacts.map(&:id)
    end
  end

  def test_plans_read_back_oldest_first_with_what_each_is_waiting_for
    Dir.mktmpdir do |tmp|
      imports = Pathname.new(tmp)
      %w[20260916T180412Z 20260915T090000Z].each do |stamp|
        Plan.write(imports / "macos-#{stamp}", source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru")])
      end
      Plan.read(imports / "macos-20260915T090000Z").record("kmnuqmzxylru", Plan::DONE)

      plans = Plan.all(imports)

      assert_equal ["macos-20260915T090000Z", "macos-20260916T180412Z"], plans.map { it.dir.basename.to_s }
      assert_equal [[], ["kmnuqmzxylru"]], plans.map { it.outstanding.map(&:id) }
    end
  end

  def test_progress_is_saved_into_the_plan_as_it_is_recorded
    in_tmpdir do |dir|
      plan = Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru"), entry("vmnlryyvktux")])

      plan.record("kmnuqmzxylru", Plan::DONE)

      read = Plan.read(dir)
      assert_equal ["done", nil], read.contacts.map(&:status)
      assert_equal ["plan.yml"], dir.children.map { it.basename.to_s }.grep(/plan/)
    end
  end

  def test_a_plan_is_done_once_every_contact_reaches_done
    in_tmpdir do |dir|
      plan = Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru"), entry("vmnlryyvktux")])

      refute plan.done?
      plan.record("kmnuqmzxylru", Plan::DONE)
      refute plan.done?
      plan.record("vmnlryyvktux", Plan::DONE)
      assert plan.done?
    end
  end

  def test_a_plan_recorded_under_the_old_vocabulary_finishes_too
    in_tmpdir do |dir|
      plan = Plan.write(dir, source: "macos", created_at: CREATED_AT, entries: [entry("kmnuqmzxylru")])
      plan.record("kmnuqmzxylru", "removed")

      assert plan.done?
    end
  end
end
