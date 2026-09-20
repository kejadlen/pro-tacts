require_relative "../../test_helper"

require "pathname"
require "tmpdir"

require "pro_tacts/import/land"
require "pro_tacts/import/plan"
require "pro_tacts/web"

# Landing a plan's cards in the store, which is what the import screen
# does with an upload (docs/plans/2026-09-20-import-by-upload.md). It
# writes through Store, so these read the store back rather than a
# response.
class ImportLandTest < Minitest::Test
  include ThrowawayContacts

  Land = ProTacts::Import::Land
  Plan = ProTacts::Import::Plan

  IDS = %w[kmnuqmzxylru vmnlryyvktux].freeze

  def with_plan(groups: [])
    Dir.mktmpdir do |tmp|
      dir = Pathname.new(tmp) / "plan"
      entries = IDS.map { |id|
        source = {"identifier" => "#{id}:ABPerson", "vcard" => "BEGIN:VCARD\r\nEND:VCARD\r\n", "note" => nil, "contact" => {}}
        card = ProTacts::Import::Card.new(first: "Contact", last: id, nickname: nil, birthday: nil, phones: [], emails: [], addresses: [], note: nil, photo: false, groups:, source:)
        Plan::Entry.new(id:, source_id: "#{id}:ABPerson", card:)
      }
      Plan.write(dir, source: "macos", created_at: Time.utc(2026, 9, 16, 18, 4, 12), entries:)
      with_contacts({}) { |store| yield Plan.read(dir), store }
    end
  end

  def cards(plan) = IDS.to_h { [it, plan.card(it)] }

  def imported_group(store) = group_named(store, "import-20260916T180412Z")

  def everyone(store) = group_named(store, "sync:*")

  def group_named(store, name)
    store.all_groups.find { it.name == name }
  end

  def edit_cards(plan)
    IDS.each do |id|
      path = plan.dir / "cards/#{id}.yml"
      path.write(yield(path.read))
    end
  end

  def test_every_card_lands_in_the_plans_group
    with_plan do |plan, store|
      arrivals = Land.call(store, cards(plan))

      IDS.each { assert_equal "Contact #{it}", store.contact(it).name }
      assert_equal IDS.sort, imported_group(store).members.sort
      assert_equal IDS.sort, everyone(store).members.sort
      assert_equal [true, true], arrivals.map(&:stored)
      assert_equal IDS, arrivals.map { it.contact.id }
    end
  end

  def test_a_second_upload_writes_nothing_again
    with_plan do |plan, store|
      Land.call(store, cards(plan))
      changes = store.changes.size

      arrivals = Land.call(store, cards(plan))

      assert_equal [false, false], arrivals.map(&:stored)
      assert_equal changes, store.changes.size
      assert_equal 1, store.all_groups.count { it.name == "import-20260916T180412Z" }
    end
  end

  # The card on the server wins, the way the PUT's `If-None-Match: *`
  # made it win: an upload is not an editor, and the person editing the
  # card here would not expect a re-upload to revert them.
  def test_a_card_already_here_is_not_written_over
    with_plan do |plan, store|
      Land.call(store, cards(plan))
      edit_cards(plan) { it.sub("first: Contact", "first: Renamed") }

      arrivals = Land.call(store, cards(plan))

      assert_equal [false, false], arrivals.map(&:stored)
      IDS.each { assert_equal "Contact #{it}", store.contact(it).name }
    end
  end

  def test_a_group_already_here_is_joined_rather_than_made_again
    with_plan do |plan, store|
      id = store.create_group(name: "import-20260916T180412Z")

      Land.call(store, cards(plan))

      assert_equal id, imported_group(store).id
      assert_equal IDS.sort, store.group(id).members.sort
    end
  end

  def test_a_card_joins_the_groups_its_file_names_making_those_missing
    with_plan(groups: ["family"]) do |plan, store|
      Land.call(store, cards(plan))

      assert_equal IDS.sort, group_named(store, "family").members.sort
      assert_equal 1, store.all_groups.count { it.name == "family" }
    end
  end

  def test_a_card_whose_file_leaves_out_everyone_is_taken_out_of_it
    with_plan do |plan, store|
      edit_cards(plan) { it.sub("- sync:*\n", "") }

      Land.call(store, cards(plan))

      assert_empty everyone(store).members
      assert_equal IDS.sort, imported_group(store).members.sort
    end
  end
end
