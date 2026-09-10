require_relative "../../test_helper"

require "pathname"
require "rack/test"
require "tmpdir"

require "pro_tacts/store"
require "pro_tacts/vcard"
require "pro_tacts/web"

# The group screens, exercised the way AdminContactsPagesTest exercises
# a contact's: real requests through the Roda app, against a throwaway
# store.
class AdminGroupsPagesTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def setup
    header "Tailscale-User-Login", "test@example.com"
  end

  def card(id, name)
    "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:#{name}\r\nUID:#{id}\r\nEND:VCARD\r\n"
  end

  ADDRESS = "ADR;TYPE=home:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom" #: String
  NOTE = "NOTE:Gate code 1854." #: String

  def with_contacts(names)
    Dir.mktmpdir do |dir|
      original = ProTacts::Web.store

      ProTacts::Store.connect(Pathname.new(dir) / "contacts.db") do |store|
        ProTacts::Web.store = store
        names.each { |id, name| store.put(id, ProTacts::VCard.new(card(id, name))) }
        yield store
      ensure
        ProTacts::Web.store = original
      end
    end
  end

  def household(store, members: %w[george mary])
    id = store.create_group(name: "Booles")
    store.set_group_lines(id, [ADDRESS, NOTE])
    members.each { store.add_member(id, it) }
    id
  end

  BOOLES = {"george" => "George Boole", "mary" => "Mary Boole", "ada" => "Ada Lovelace"}.freeze

  ## The list

  def test_the_list_names_every_group_and_its_size
    with_contacts(BOOLES) do |store|
      id = household(store)
      nameless = store.create_group

      get "/groups"

      assert_equal 200, last_response.status
      assert_includes last_response.body, %(<a href="/groups/#{id}">)
      assert_includes last_response.body, "Booles"
      assert_includes last_response.body, "2 members"
      assert_includes last_response.body, nameless
    end
  end

  def test_an_empty_list_says_so
    with_contacts({}) do
      get "/groups"

      assert_includes last_response.body, "No groups yet."
    end
  end

  def test_the_footer_leads_to_the_groups
    with_contacts({}) do
      get "/"

      assert_includes last_response.body, %(<a href="/groups" class="type-label">groups</a>)
    end
  end

  ## Creating

  # A new group is nothing until something is added to it, so the
  # create lands on its editor.
  def test_a_create_lands_on_the_new_groups_editor
    with_contacts({}) do |store|
      post "/groups", name: "Booles"

      id = store.all_groups.fetch(0).id
      assert_equal 303, last_response.status
      assert_equal "/groups/#{id}/edit", URI(last_response["Location"]).path
      assert_equal "Booles", store.group(id).name
    end
  end

  def test_a_blank_create_makes_a_nameless_group
    with_contacts({}) do |store|
      post "/groups", name: "  "

      assert_nil store.all_groups.fetch(0).name
    end
  end

  ## The card

  def test_the_card_shows_what_the_group_lends_and_to_whom
    with_contacts(BOOLES) do |store|
      id = household(store)

      get "/groups/#{id}"

      body = last_response.body
      assert_equal 200, last_response.status
      assert_includes body, "7 Calculus Close"
      assert_includes body, "Gate code 1854."
      assert_includes body, %(<a href="/contacts/george" class="tag">George Boole</a>)
      assert_includes body, %(<a href="/contacts/mary" class="tag">Mary Boole</a>)
      refute_includes body, "Ada Lovelace"
    end
  end

  def test_an_unknown_group_is_a_404
    with_contacts({}) do
      get "/groups/zzzz"
      assert_equal 404, last_response.status

      get "/groups/zzzz/edit"
      assert_equal 404, last_response.status
    end
  end

  ## The editor

  def test_the_editor_checks_the_members_and_offers_everyone_else
    with_contacts(BOOLES) do |store|
      id = household(store)

      get "/groups/#{id}/edit"

      body = last_response.body
      assert_includes body, %(<input type="hidden" name="version" value="#{store.group(id).version}">)
      assert_includes body, %(<input type="checkbox" name="members[]" value="george" checked>)
      assert_includes body, %(<input type="checkbox" name="members[]" value="ada" form="group-form">)
      assert_includes body, %(name="address[)
    end
  end

  # The whole save: the name, a line, and the membership in one POST,
  # and every card whose served bytes moved told so in the change log.
  def test_a_save_writes_the_name_the_lines_and_the_members
    with_contacts(BOOLES) do |store|
      id = household(store)
      group = store.group(id)

      post "/groups/#{id}", version: group.version, name: "The Booles", note: "Gate code 1912.",
                            members: ["", "george", "ada"]

      assert_equal 303, last_response.status
      saved = store.group(id)
      assert_equal "The Booles", saved.name
      assert_equal [ADDRESS, "NOTE:Gate code 1912."], saved.lines
      assert_equal %w[ada george], saved.members
      assert_includes store.contact("ada").vcard.to_s, ADDRESS
      refute_includes store.contact("mary").vcard.to_s, ADDRESS
      assert_equal "group", store.changes_of("mary").first.action
    end
  end

  def test_a_save_edits_and_adds_an_address
    with_contacts(BOOLES) do |store|
      id = household(store)
      group = store.group(id)
      digest = group.reading.addresses.fetch(0).line.digest

      post "/groups/#{id}", version: group.version, note: "Gate code 1854.", members: ["", "george", "mary"],
                            address: {digest => {street: "8 Calculus Close", locality: "London",
                                                 region: "England", postal_code: "NW1 1AB",
                                                 country: "United Kingdom"}},
                            new_address: {"0" => {street: "1 Long Road"}}

      assert_equal [ADDRESS.sub("7 Calculus", "8 Calculus"), NOTE, "ADR:;;1 Long Road;;;;"],
                   store.group(id).lines
    end
  end

  # The snapshot guard, the contact editor's: a group changed since the
  # page loaded refuses the stale save rather than reverting the change.
  def test_a_stale_save_is_refused_and_changes_nothing
    with_contacts(BOOLES) do |store|
      id = household(store)
      stale = store.group(id).version
      store.rename_group(id, name: "The Booles")

      post "/groups/#{id}", version: stale, name: "Booles", members: [""]

      assert_equal 200, last_response.status
      assert_includes last_response.body, "This group changed since the page loaded; nothing was saved."
      assert_equal "The Booles", store.group(id).name
      assert_equal %w[george mary], store.group(id).members
    end
  end

  # No list at all is a POST that says nothing about membership; a
  # doctored id names no card and is dropped rather than a 500.
  def test_membership_moves_only_for_a_list_of_real_cards
    with_contacts(BOOLES) do |store|
      id = household(store)

      post "/groups/#{id}", version: store.group(id).version, note: "Gate code 1854."
      assert_equal %w[george mary], store.group(id).members

      post "/groups/#{id}", version: store.group(id).version, note: "Gate code 1854.",
                            members: ["", "george", "nobody"]
      assert_equal 303, last_response.status
      assert_equal %w[george], store.group(id).members
    end
  end

  ## Search

  def test_search_finds_a_group_by_its_name
    with_contacts(BOOLES) do |store|
      id = household(store)

      get "/", q: "boole"

      assert_includes last_response.body, %(<a href="/groups/#{id}">)
    end
  end

  def test_search_finds_a_contact_by_its_groups_name
    with_contacts({"george" => "George", "ada" => "Ada Lovelace"}) do |store|
      household(store, members: ["george"])

      get "/", q: "boole"

      assert_includes last_response.body, %(<a href="/contacts/george">)
      refute_includes last_response.body, %(<a href="/contacts/ada">)
    end
  end
end
