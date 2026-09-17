require_relative "../../test_helper"

require "pathname"
require "rack/mock"
require "tmpdir"

require "pro_tacts/import/execute"
require "pro_tacts/import/plan"
require "pro_tacts/import/remove"
require "pro_tacts/web"

class ImportRemoveTest < Minitest::Test
  include ThrowawayContacts

  Card = ProTacts::Import::Card
  Plan = ProTacts::Import::Plan
  Execute = ProTacts::Import::Execute
  Remove = ProTacts::Import::Remove

  HOST = "https://contacts"
  IDS = %w[kmnuqmzxylru vmnlryyvktux].freeze

  # This Mac, as the contacts it still has: the reader's objects by source
  # id, and a delete that takes them out of this hash.
  class Mac
    attr_reader :deleted

    def initialize(records)
      @records = records
      @deleted = []
    end

    def show(source_ids) = @records.slice(*source_ids)

    def delete(source_ids)
      @deleted.concat(source_ids)
      @records = @records.except(*source_ids)
    end
  end

  def vcard(id) = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Contact #{id}\r\nEND:VCARD\r\n"

  def source_id(id) = "#{id}:ABPerson"

  def record(id, note: nil)
    {"identifier" => source_id(id), "vcard" => vcard(id), "note" => note}
  end

  # A plan already landed on the host, since that is what remove works on.
  def with_landed_plan(notes: {}, edit: nil)
    Dir.mktmpdir do |tmp|
      dir = Pathname.new(tmp) / "plan"
      entries = IDS.map { |id|
        backup = {"original.vcf" => vcard(id)}
        backup["note.txt"] = notes.fetch(id) if notes.key?(id)
        card = Card.new(first: "Contact", last: id, phones: [], groups: [])
        Plan::Entry.new(id:, source_id: source_id(id), card:, backup:)
      }
      Plan.write(dir, source: "macos", created_at: Time.utc(2026, 9, 16, 18, 4, 12), entries:)
      IDS.each { (dir / "cards/#{it}.yml").write(edit.call((dir / "cards/#{it}.yml").read)) } if edit
      with_contacts({}) do |store|
        client = ImportExecuteTest::RackClient.new
        plan = Plan.read(dir)
        Execute.call(plan, host: HOST, client:)
        yield plan, store, client
      end
    end
  end

  def test_a_contact_that_matches_its_backup_leaves_the_mac
    with_landed_plan do |plan, _store, client|
      mac = Mac.new(IDS.to_h { [source_id(it), record(it)] })

      result = Remove.call(plan, client:, mac:)

      assert_equal 2, result.removed
      assert_empty result.kept
      assert_equal IDS.map { source_id(it) }, mac.deleted
      assert_equal %w[removed removed], Plan.read(plan.dir).contacts.map(&:status)
    end
  end

  def test_a_contact_changed_on_the_mac_is_kept
    with_landed_plan do |plan, _store, client|
      records = IDS.to_h { [source_id(it), record(it)] }
      records[source_id(IDS.first)]["vcard"] = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Renamed\r\nEND:VCARD\r\n"
      mac = Mac.new(records)

      result = Remove.call(plan, client:, mac:)

      assert_equal [["Contact #{IDS.first}", "it has changed on this Mac since the plan"]], result.kept
      assert_equal [source_id(IDS.last)], mac.deleted
      assert_equal ["imported", "removed"], Plan.read(plan.dir).contacts.map(&:status)
    end
  end

  def test_a_note_written_since_the_plan_keeps_its_contact
    with_landed_plan(notes: {IDS.first => "Analyst."}) do |plan, _store, client|
      records = IDS.to_h { [source_id(it), record(it)] }
      records[source_id(IDS.first)]["note"] = "Analyst. Also a countess."
      mac = Mac.new(records)

      result = Remove.call(plan, client:, mac:)

      assert_equal [["Contact #{IDS.first}", "its note has changed on this Mac since the plan"]], result.kept
      assert_equal [source_id(IDS.last)], mac.deleted
    end
  end

  def test_a_contact_whose_card_left_the_host_is_kept
    with_landed_plan do |plan, store, client|
      store.delete(IDS.first)
      mac = Mac.new(IDS.to_h { [source_id(it), record(it)] })

      result = Remove.call(plan, client:, mac:)

      assert_equal [["Contact #{IDS.first}", "its card is no longer on #{HOST}"]], result.kept
      assert_equal [source_id(IDS.last)], mac.deleted
    end
  end

  # The card browser shows every card; /dav/addressbook serves the asking
  # user's book, which a card in no `sync:` group is outside of.
  def test_a_contact_whose_card_is_in_no_book_still_leaves_the_mac
    with_landed_plan(edit: ->(yaml) { yaml.sub("- sync:*\n", "") }) do |plan, store, client|
      refute_includes store.book("test@example.com"), IDS.first
      mac = Mac.new(IDS.to_h { [source_id(it), record(it)] })

      result = Remove.call(plan, client:, mac:)

      assert_empty result.kept
      assert_equal IDS.map { source_id(it) }, mac.deleted
    end
  end

  def test_a_contact_already_off_the_mac_counts_as_removed
    with_landed_plan do |plan, _store, client|
      mac = Mac.new({source_id(IDS.last) => record(IDS.last)})

      result = Remove.call(plan, client:, mac:)

      assert_equal 2, result.removed
      assert_equal [source_id(IDS.last)], mac.deleted
      assert_equal %w[removed removed], Plan.read(plan.dir).contacts.map(&:status)
    end
  end

  def test_a_rerun_removes_nothing_again
    with_landed_plan do |plan, _store, client|
      mac = Mac.new(IDS.to_h { [source_id(it), record(it)] })
      Remove.call(plan, client:, mac:)

      result = Remove.call(Plan.read(plan.dir), client:, mac:)

      assert_equal 0, result.removed
      assert_equal IDS.map { source_id(it) }, mac.deleted
    end
  end
end
