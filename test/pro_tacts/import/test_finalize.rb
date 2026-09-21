require_relative "../../test_helper"

require "pathname"
require "rack/mock"
require "tmpdir"

require "pro_tacts/import/execute"
require "pro_tacts/import/plan"
require "pro_tacts/import/finalize"
require "pro_tacts/web"

class ImportFinalizeTest < Minitest::Test
  include ThrowawayContacts

  Card = ProTacts::Import::Card
  Plan = ProTacts::Import::Plan
  Execute = ProTacts::Import::Execute
  Finalize = ProTacts::Import::Finalize

  HOST = "https://contacts"
  IDS = %w[kmnuqmzxylru vmnlryyvktux].freeze

  # This Mac, as the contacts it still has: the reader's objects by source
  # id, and a delete that takes them out of this hash. A source id in
  # `refuses` is one the store will not delete, which is a real thing a Mac
  # does (docs/plans/2026-09-16-importing-from-macos.md, "Removing the
  # originals").
  class Mac
    attr_reader :deleted

    def initialize(records, refuses: {})
      @records = records
      @refuses = refuses
      @deleted = []
    end

    def show(source_ids) = @records.slice(*source_ids)

    def delete(source_ids)
      going = source_ids - @refuses.keys
      @deleted.concat(going)
      @records = @records.except(*going)
      @refuses.slice(*source_ids)
    end
  end

  def vcard(id) = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Contact #{id}\r\nEND:VCARD\r\n"

  def source_id(id) = "#{id}:ABPerson"

  def record(id, note: nil)
    {"identifier" => source_id(id), "vcard" => vcard(id), "note" => note}
  end

  # A plan already landed on the host, since that is what finalize works on.
  def with_landed_plan(notes: {}, edit: nil)
    Dir.mktmpdir do |tmp|
      dir = Pathname.new(tmp) / "plan"
      entries = IDS.map { |id|
        source = {"identifier" => source_id(id), "vcard" => vcard(id), "note" => notes[id], "contact" => {}}
        card = Card.new(first: "Contact", last: id, nickname: nil, birthday: nil, phones: [], emails: [], addresses: [], note: nil, photo: false, groups: [], source:)
        Plan::Entry.new(id:, source_id: source_id(id), card:)
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

  def test_a_contact_that_matches_its_source_leaves_the_mac
    with_landed_plan do |plan, _store, client|
      mac = Mac.new(IDS.to_h { [source_id(it), record(it)] })

      result = Finalize.call(plan, client:, mac:)

      assert_equal 2, result.done
      assert_empty result.kept
      assert_equal IDS.map { source_id(it) }, mac.deleted
      assert_equal %w[done done], Plan.read(plan.dir).contacts.map(&:status)
    end
  end

  def test_a_contact_changed_on_the_mac_is_kept
    with_landed_plan do |plan, _store, client|
      records = IDS.to_h { [source_id(it), record(it)] }
      records[source_id(IDS.first)]["vcard"] = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Renamed\r\nEND:VCARD\r\n"
      mac = Mac.new(records)

      result = Finalize.call(plan, client:, mac:)

      assert_equal [[IDS.first, "Contact #{IDS.first}", "it has changed on this Mac since the plan"]], result.kept
      assert_equal [source_id(IDS.last)], mac.deleted
      assert_equal ["imported", "done"], Plan.read(plan.dir).contacts.map(&:status)
    end
  end

  def test_a_note_written_since_the_plan_keeps_its_contact
    with_landed_plan(notes: {IDS.first => "Analyst."}) do |plan, _store, client|
      records = IDS.to_h { [source_id(it), record(it)] }
      records[source_id(IDS.first)]["note"] = "Analyst. Also a countess."
      mac = Mac.new(records)

      result = Finalize.call(plan, client:, mac:)

      assert_equal [[IDS.first, "Contact #{IDS.first}", "its note has changed on this Mac since the plan"]], result.kept
      assert_equal [source_id(IDS.last)], mac.deleted
    end
  end

  def test_a_contact_whose_card_left_the_host_is_kept
    with_landed_plan do |plan, store, client|
      store.delete(IDS.first)
      mac = Mac.new(IDS.to_h { [source_id(it), record(it)] })

      result = Finalize.call(plan, client:, mac:)

      assert_equal [[IDS.first, "Contact #{IDS.first}", "its card is no longer on #{HOST}"]], result.kept
      assert_equal [source_id(IDS.last)], mac.deleted
    end
  end

  # The card browser shows every card; /dav/addressbook serves the asking
  # user's book, which a card in no `sync:` group is outside of.
  def test_a_contact_whose_card_is_in_no_book_still_leaves_the_mac
    with_landed_plan(edit: ->(yaml) { yaml.sub("- sync:*\n", "") }) do |plan, store, client|
      refute_includes store.book_cards("test@example.com"), IDS.first
      mac = Mac.new(IDS.to_h { [source_id(it), record(it)] })

      result = Finalize.call(plan, client:, mac:)

      assert_empty result.kept
      assert_equal IDS.map { source_id(it) }, mac.deleted
    end
  end

  def test_a_contact_already_off_the_mac_counts_as_done
    with_landed_plan do |plan, _store, client|
      mac = Mac.new({source_id(IDS.last) => record(IDS.last)})

      result = Finalize.call(plan, client:, mac:)

      assert_equal 2, result.done
      assert_equal [source_id(IDS.last)], mac.deleted
      assert_equal %w[done done], Plan.read(plan.dir).contacts.map(&:status)
    end
  end

  # The store refuses some contacts it will hand over quite happily, so a
  # refusal keeps its own contact and no other: the rest still leave, and
  # the plan records them.
  def test_a_contact_the_mac_will_not_delete_is_kept_alone
    with_landed_plan do |plan, _store, client|
      mac = Mac.new(IDS.to_h { [source_id(it), record(it)] }, refuses: {source_id(IDS.first) => "faulting, 134092"})

      result = Finalize.call(plan, client:, mac:)

      assert_equal 1, result.done
      assert_equal [[IDS.first, "Contact #{IDS.first}", "this Mac would not delete #{source_id(IDS.first)}: faulting, 134092"]], result.kept
      assert_equal [source_id(IDS.last)], mac.deleted
      assert_equal ["imported", "done"], Plan.read(plan.dir).contacts.map(&:status)
    end
  end

  def test_a_rerun_finalizes_nothing_again
    with_landed_plan do |plan, _store, client|
      mac = Mac.new(IDS.to_h { [source_id(it), record(it)] })
      Finalize.call(plan, client:, mac:)

      result = Finalize.call(Plan.read(plan.dir), client:, mac:)

      assert_equal 0, result.done
      assert_equal IDS.map { source_id(it) }, mac.deleted
    end
  end
end
