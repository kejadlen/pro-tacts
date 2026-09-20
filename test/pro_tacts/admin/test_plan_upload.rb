require_relative "../../test_helper"

require "pathname"
require "rack/test"
require "tmpdir"

require "pro_tacts/import/plan"
require "pro_tacts/web"

# The import screen, exercised the way the other admin screens are:
# real requests through the Roda app against a throwaway store
# (docs/plans/2026-09-20-import-by-upload.md).
class AdminPlanUploadTest < Minitest::Test
  include Rack::Test::Methods
  include ThrowawayContacts

  Plan = ProTacts::Import::Plan

  IDS = %w[kmnuqmzxylru vmnlryyvktux].freeze

  def app
    ProTacts::Web
  end

  def setup
    header "Remote-User", "test@example.com"
  end

  # A plan on disk, as `rake import:macos:plan` leaves one, and a store
  # with nothing in it for its cards to land in.
  def with_plan
    Dir.mktmpdir do |tmp|
      dir = Pathname.new(tmp) / "plan"
      entries = IDS.map { |id|
        source = {"identifier" => "#{id}:ABPerson", "vcard" => "BEGIN:VCARD\r\nEND:VCARD\r\n", "note" => nil, "contact" => {}}
        card = ProTacts::Import::Card.new(first: "Contact", last: id, nickname: nil, birthday: nil, phones: [], emails: [], addresses: [], note: nil, photo: false, groups: [], source:)
        Plan::Entry.new(id:, source_id: "#{id}:ABPerson", card:)
      }
      Plan.write(dir, source: "macos", created_at: Time.utc(2026, 9, 16, 18, 4, 12), entries:)
      with_contacts({}) { |store| yield dir, store }
    end
  end

  def upload(path) = Rack::Test::UploadedFile.new(path.to_s, "application/yaml", true)

  def upload_cards(dir, paths = IDS.map { dir / "cards/#{it}.yml" })
    post "/import", "cards" => paths.map { upload(it) }
  end

  def test_the_screen_asks_for_a_plans_cards
    with_plan do |_dir, _store|
      get "/import"

      assert_equal 200, last_response.status
      assert_includes last_response.body, %(<form action="/import" method="post" enctype="multipart/form-data")
      assert_includes last_response.body, %(<input type="file" name="cards[]" multiple accept=".yml">)
    end
  end

  def test_uploaded_cards_land_as_contacts_in_the_plans_group
    with_plan do |dir, store|
      upload_cards(dir)

      assert_equal 200, last_response.status
      IDS.each { assert_equal "Contact #{it}", store.contact(it).name }
      assert_equal IDS.sort, store.all_groups.find { it.name == "import-20260916T180412Z" }.members.sort
      assert_includes last_response.body, "landed (2 of 2)"
      IDS.each { assert_includes last_response.body, %(href="/contacts/#{it}") }
    end
  end

  def test_a_card_already_here_is_said_so_rather_than_landed_again
    with_plan do |dir, store|
      upload_cards(dir)
      changes = store.changes.size

      upload_cards(dir)

      assert_includes last_response.body, "landed (0 of 2)"
      assert_includes last_response.body, "already here"
      assert_equal changes, store.changes.size
    end
  end

  def test_an_upload_with_no_files_says_what_to_choose
    with_plan do |_dir, store|
      post "/import"

      assert_includes last_response.body, "Choose the card files in a plan&#39;s cards directory."
      assert_empty store.changes
    end
  end

  def test_a_card_that_will_not_read_lands_nothing
    with_plan do |dir, store|
      path = dir / "cards/#{IDS.last}.yml"
      path.write(path.read.sub("last: #{IDS.last}", "last: no"))

      upload_cards(dir)

      assert_includes last_response.body, "#{IDS.last}.yml: first and last must be text; quote them"
      assert_empty store.changes
    end
  end

  # The filename is the id the card lands under, so a file named
  # anything else is a file from somewhere other than a plan.
  def test_a_file_that_is_not_a_plan_card_lands_nothing
    with_plan do |dir, store|
      (dir / "cards/notes.txt").write("hello")

      upload_cards(dir, [dir / "cards/notes.txt"])

      assert_includes last_response.body, "notes.txt is not a plan card"
      assert_empty store.changes
    end
  end

  # Web#write_card's rule over the one other body this app reads: bytes
  # that are not the text they claim to be are refused where they are
  # read, rather than at the insert that would 500 on them.
  def test_a_card_that_is_not_utf_8_lands_nothing
    with_plan do |dir, store|
      path = dir / "cards/#{IDS.first}.yml"
      path.binwrite(path.read.sub("Contact", "Contac\xFF"))

      upload_cards(dir)

      assert_includes last_response.body, "#{IDS.first}.yml is not UTF-8 text."
      assert_empty store.changes
    end
  end
end
