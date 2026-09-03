require_relative "../../test_helper"

require "date"
require "pathname"
require "rack/test"
require "tmpdir"

require "pro_tacts/store"
require "pro_tacts/web"

# The upcoming-birthdays screen, exercised like the other admin pages:
# real requests through the Roda app, against a throwaway store. The
# query's own behavior — the year wrap, which partial shapes place on
# a day at all — is test_store.rb's; here what is under test is what
# the screen makes of what it hands back. The route reads the real
# clock, so the cards are built around Date.today rather than a fixed
# date.
class AdminBirthdaysPageTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def setup
    header "Tailscale-User-Login", "test@example.com"
  end

  # A contact born on `date`'s month and day in 2000, so the page's
  # ordering and labels are deterministic against the real clock.
  def born(date, name:, id:)
    "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:#{name}\r\n" \
      "BDAY:2000-%02d-%02d\r\nUID:#{id}\r\nEND:VCARD\r\n" % [date.month, date.day]
  end

  def with_contacts(cards)
    Dir.mktmpdir do |dir|
      original = ProTacts::Web.store

      ProTacts::Store.connect(Pathname.new(dir) / "contacts.db") do |store|
        ProTacts::Web.store = store
        cards.each { |id, card| store.put(id, card) }
        yield store
      ensure
        ProTacts::Web.store = original
      end
    end
  end

  # The list answers "who is next": names in arrival order, each row
  # opening the contact's card, the birthday shown with the age it
  # turns and the day counted down beside it.
  def test_lists_birthdays_in_arrival_order_linking_to_the_contact
    tomorrow = born(Date.today + 1, name: "Sooner Person", id: "sooner")
    fortnight = born(Date.today + 13, name: "Later Person", id: "later")

    with_contacts({"later" => fortnight, "sooner" => tomorrow}) do
      get "/birthdays"

      assert_equal 200, last_response.status
      assert_equal "text/html; charset=utf-8", last_response["Content-Type"]
      body = last_response.body
      assert body.index("Sooner Person") < body.index("Later Person")
      assert_includes body, 'href="/contacts/sooner"'
      assert_includes body, "(turns #{(Date.today + 1).year - 2000})"
      assert_includes body, "tomorrow"
      assert_includes body, "in 13d"
    end
  end

  # A birthday without a year is on the day — shown with no age, the
  # one thing a missing year cannot answer.
  def test_a_birthday_without_a_year_shows_no_age
    week = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:No Year\r\n" \
      "BDAY;X-APPLE-OMIT-YEAR=1604:1604-%02d-%02d\r\nUID:noyear\r\nEND:VCARD\r\n" %
      [(Date.today + 7).month, (Date.today + 7).day]

    with_contacts({"noyear" => week}) do
      get "/birthdays"

      body = last_response.body
      assert_includes body, "No Year"
      assert_includes body, "in 7d"
      refute_includes body, "turns"
    end
  end

  def test_no_birthdays_says_so
    with_contacts({}) { get "/birthdays" }

    assert_includes last_response.body, "No birthdays to show."
  end

  # The screen is reachable from the page shell every screen shares.
  def test_the_header_links_to_birthdays
    with_contacts({}) do
      get "/"

      assert_includes last_response.body, 'href="/birthdays"'
    end
  end
end
