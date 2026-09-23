require_relative "../../test_helper"

require "pro_tacts/contact"
require "pro_tacts/import/match"

# The contacts an arriving card might be
# (docs/plans/2026-09-23-merging-on-import.md).
class ImportMatchTest < Minitest::Test
  Match = ProTacts::Import::Match

  def contact(id, name, *lines)
    card = ["BEGIN:VCARD", "VERSION:3.0", "FN:#{name}", *lines, "UID:#{id}", "END:VCARD", ""].join("\r\n")
    ProTacts::Contact.new(id:, stored: ProTacts::VCard.new(card), birthday: nil, inherited: [])
  end

  def test_the_distance_is_levenshteins
    assert_equal 0, Match.distance("booles", "booles")
    assert_equal 3, Match.distance("kitten", "sitting")
    assert_equal 4, Match.distance("", "jane")
    assert_equal 1, Match.distance("jon", "john")
  end

  def test_a_name_spelled_a_little_differently_is_offered
    arriving = contact("0", "Jon Smith")
    john = contact("john", "John Smith")

    assert_equal [john], Match.candidates(arriving, [john, contact("sam", "Sam Booles")])
  end

  # The words of a name, not the order an export wrote them in.
  def test_a_name_written_family_first_is_the_same_name
    arriving = contact("0", "Booles, Jane")
    jane = contact("jane", "Jane Booles")

    assert_equal [jane], Match.candidates(arriving, [jane])
  end

  def test_an_email_address_is_enough_and_its_case_is_not_part_of_it
    arriving = contact("0", "J. B.", "EMAIL:Jane@Example.com")
    jane = contact("jane", "Jane Booles", "EMAIL;type=INTERNET:jane@example.com")

    assert_equal [jane], Match.candidates(arriving, [jane])
  end

  # Two addresses are alike by the part before the @, and only at one
  # domain: another domain is another mailbox, and a shared one says
  # nothing about the people at it.
  def test_an_address_is_alike_by_its_mailbox_at_the_same_domain
    jane = contact("jane", "Jane Booles", "EMAIL:jane.booles@example.com")
    ada = contact("ada", "Ada Lovelace", "EMAIL:ada@example.com")

    assert_equal [jane], Match.candidates(contact("0", "J", "EMAIL:jane.boole@example.com"), [jane, ada])
    assert_empty Match.candidates(contact("0", "J", "EMAIL:jane.booles@elsewhere.org"), [jane])
    assert_empty Match.candidates(contact("0", "M", "EMAIL:mary@example.com"), [ada])
  end

  # A country code on one side and not the other is still one number.
  def test_a_phone_number_is_enough_however_it_is_written
    arriving = contact("0", "Mom", "TEL:+1 (555) 010-0200")
    mother = contact("mother", "Ruth Booles", "TEL;type=CELL:555-010-0200")

    assert_equal [mother], Match.candidates(arriving, [mother])
  end

  # A digit mistyped is one edit in ten.
  def test_a_phone_number_a_digit_off_is_offered
    arriving = contact("0", "Mom", "TEL:+44 7700 900461")
    george = contact("george", "George Boole", "TEL:+44 7700 900467")

    assert_equal [george], Match.candidates(arriving, [george, contact("mary", "Mary Boole", "TEL:+44 7700 900218")])
  end

  def test_nothing_alike_is_nothing_offered
    arriving = contact("0", "Jane Booles", "TEL:555 0100", "EMAIL:jane@example.com")

    assert_empty Match.candidates(arriving, [contact("x", "Theo Marsh", "TEL:212 867 5309", "EMAIL:theo@elsewhere.org")])
  end

  def test_the_closest_come_first_and_only_a_few_of_them
    arriving = contact("0", "Jane Booles")
    exact = contact("exact", "Jane Booles")
    near = contact("near", "Jane Boole")
    others = %w[Jane\ Bools Jane\ Bowles Jane\ Booler].each_with_index.map { |name, i| contact("o#{i}", name) }

    offered = Match.candidates(arriving, [near, *others, exact])

    assert_equal Match::LIMIT, offered.length
    assert_equal "exact", offered.first.id
  end

  # One field is enough to be offered, and agreeing on more ranks
  # higher: an address two contacts share puts the one with the name
  # first.
  def test_the_contact_agreeing_on_more_comes_first
    arriving = contact("0", "Ada Lovelace", "EMAIL:ada@example.com")
    shared = contact("emoji", "Emoji Contact", "EMAIL:ada@example.com")
    ada = contact("ada", "Ada Lovelace", "EMAIL:ada@example.com")

    assert_equal %w[ada emoji], Match.candidates(arriving, [shared, ada]).map(&:id)
  end

  def test_a_card_with_nothing_to_compare_matches_nothing
    arriving = ProTacts::Contact.new(
      id: "0", stored: ProTacts::VCard.new("BEGIN:VCARD\r\nVERSION:3.0\r\nEND:VCARD\r\n"), birthday: nil, inherited: [],
    )

    assert_empty Match.candidates(arriving, [contact("jane", "Jane Booles")])
  end
end
