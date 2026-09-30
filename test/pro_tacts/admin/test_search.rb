require_relative "../../test_helper"

require "pro_tacts/admin/search"
require "pro_tacts/contact"
require "pro_tacts/group"
require "pro_tacts/store"
require "pro_tacts/vcard"

class SearchTest < Minitest::Test
  # A card from its extra lines, and its row in recency order: the
  # rows arrive most recent first, the way Store#contacts_by_recency
  # hands them over.
  def row(id, name, *lines)
    bytes = ["BEGIN:VCARD", "VERSION:3.0", "FN:#{name}", "UID:#{id}", *lines, "END:VCARD", ""].join("\r\n")
    contact = ProTacts::Contact.new(id:, stored: ProTacts::VCard.new(bytes), birthday: nil, inherited: [])
    ProTacts::Store::RecentContact.new(contact:, updated_at: Time.now)
  end

  def search(rows, query, groups: [])
    ProTacts::Admin::Search.contacts(rows, query:, groups:).map { it.contact.id }
  end

  # Each word finds its own field: neither "ada" nor "london" is
  # the whole of any one value.
  def test_every_word_matches_somewhere_in_the_contact
    ada = row("ada", "Ada Lovelace", "ADR:;;12 St James Sq;London;;;UK")
    grace = row("grace", "Grace Hopper", "ADR:;;1 Main St;London;;;UK")

    assert_equal ["ada"], search([ada, grace], "ada london")
    assert_equal [], search([ada, grace], "ada arlington")
  end

  # A number is found by its digits whatever punctuation the card
  # and the query spell it with.
  def test_a_phone_compares_digits_only
    ada = row("ada", "Ada Lovelace", "TEL:(555) 010-0100")

    assert_equal ["ada"], search([ada], "555-010-0100")
    assert_equal ["ada"], search([ada], "5550100100")
    assert_equal ["ada"], search([ada], "0100")
  end

  # A word with letters in it is not a number, so its digits alone do
  # not reach a phone.
  def test_a_word_with_letters_does_not_match_a_phone
    ada = row("ada", "Ada Lovelace", "TEL:555-0100")

    assert_equal [], search([ada], "x555")
  end

  def test_addresses_and_notes_are_values_a_search_finds
    ada = row("ada", "Ada Lovelace", "ADR:;;12 St James Sq;London;;;UK", "NOTE:Met at the Analytical Society")

    assert_equal ["ada"], search([ada], "james sq")
    assert_equal ["ada"], search([ada], "analytical")
  end

  def test_the_groups_a_contact_is_in_find_it
    ada = row("ada", "Ada Lovelace")
    math = ProTacts::Group.new(id: "math", name: "Mathematicians", label: "Mathematicians", lines: [], members: ["ada"])

    assert_equal ["ada"], search([ada], "mathematicians", groups: [math])
  end

  # Charles is the more recent, and only his note says "ada"; Ada's
  # name does, so she leads anyway. Within a tier, recency stands:
  # the two notes keep the order they arrived in.
  def test_a_name_prefix_hit_ranks_above_a_hit_elsewhere
    charles = row("charles", "Charles Babbage", "NOTE:Worked with Ada")
    byron = row("byron", "Lord Byron", "NOTE:Father of Ada")
    ada = row("ada", "Ada Lovelace")

    assert_equal ["ada", "charles", "byron"], search([charles, byron, ada], "ada")
  end

  # A prefix of a later word of the name counts, and so does the
  # nickname; a match inside a word is still a match, just not a name
  # hit.
  def test_a_name_hit_is_a_prefix_of_any_word_of_the_name_or_nickname
    lovelace = row("ada", "Ada Lovelace")
    red = row("red", "Sarah Jones", "NICKNAME:Lovey")
    clove = row("clove", "Clove Smith")

    assert_equal ["ada", "red", "clove"], search([clove, lovelace, red], "love")
  end
end
