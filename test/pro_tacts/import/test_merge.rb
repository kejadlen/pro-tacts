require_relative "../../test_helper"

require "hegel"

require "pro_tacts/contact"
require "pro_tacts/import/merge"

# An arriving card folded into a contact the book already has
# (docs/plans/2026-09-23-merging-on-import.md).
class ImportMergeTest < Minitest::Test
  include Hegel::Syntax::Methods

  Merge = ProTacts::Import::Merge

  STORED = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Jane;;;
    FN:Jane Booles
    TEL;type=CELL:555-010-0100
    item1.EMAIL;type=INTERNET:jane@example.com
    item1.X-ABLabel:_$!<Home>!$_
    NOTE:Met at work
    UID:jane
    END:VCARD
  CARD

  ARRIVING = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Janet;;;
    FN:Janet Booles
    TEL;type=CELL:+1 (555) 010-0100
    TEL;type=WORK:555 010 0199
    item1.EMAIL:jane@work.example
    item1.X-ABLabel:_$!<Work>!$_
    NICKNAME:JB
    NOTE:From the school list
    BDAY:1985-04-12
    UID:ABC-123
    END:VCARD
  CARD

  def jane(card = STORED, birthday: nil)
    ProTacts::ContactDetails.of_card(card: ProTacts::VCard.new(card), birthday:)
  end

  def merge(into = jane, arriving = ARRIVING) = Merge.new(into, ProTacts::VCard.new(arriving))

  # The contact's own card is the base, byte for byte — the note
  # among it, which the entity holds as a component and serves
  # composed at the end rather than in the card's own lines.
  def test_the_contact_keeps_every_line_it_had
    folded = merge.contact.stored.to_s

    STORED.each_line.reject { |line| line.start_with?("END:", "NOTE:") }.each do |line|
      assert_includes folded, line
    end
    assert_equal "Met at work", merge.contact.note
    assert_includes merge.contact.vcard.to_s, "NOTE:Met at work\r\n"
    refute_includes folded, "ABC-123"
  end

  # A number already on the contact, written another way, stays one
  # number; a new one comes in beside it.
  def test_a_number_it_lacks_comes_in_and_one_it_has_does_not
    phones = merge.contact.phones.map(&:value)

    assert_equal ["555-010-0100", "555 010 0199"], phones
  end

  # A handle is one of many, like an email: a new one comes in, and
  # one the contact has does not come in twice.
  def test_a_handle_it_lacks_comes_in_and_one_it_has_does_not
    signal = "IMPP;X-SERVICE-TYPE=signal:x-apple:jb.01\r\n"
    into = jane(STORED.sub("UID:", "#{signal}UID:"))
    arriving = ARRIVING.sub("UID:", "#{signal}IMPP;X-SERVICE-TYPE=signal:x-apple:janet.02\r\nUID:")

    assert_equal ["jb.01", "janet.02"], merge(into, arriving).contact.handles.map(&:value)
  end

  # Apple numbers `item` groups per card, so the arriving email's
  # item1 would collide with the contact's own: it is renumbered, and
  # its label goes with it.
  def test_a_grouped_line_is_renumbered_with_its_label
    folded = merge.contact.stored.to_s

    assert_includes folded, "item2.EMAIL:jane@work.example\r\nitem2.X-ABLabel:_$!<Work>!$_\r\n"
    assert_includes folded, "item1.X-ABLabel:_$!<Home>!$_\r\n"
  end

  # What a contact holds one of fills a gap and does not overwrite.
  def test_the_books_own_name_and_note_stand_and_a_missing_nickname_comes_in
    folded = merge.contact

    assert_equal "Jane Booles", folded.name
    assert_equal "Met at work", folded.note
    assert_equal "JB", folded.nickname
  end

  # A contact holds one note, so several arriving fill the gap as one
  # value — a blank line between, the shape the write path joins
  # foreign input into and the sections read beside
  # (docs/plans/2026-09-25-one-note-per-contact.md).
  def test_several_arriving_notes_join_into_the_one_gap
    bare = <<~CARD.gsub("\n", "\r\n")
      BEGIN:VCARD
      VERSION:3.0
      N:Booles;Janet;;;
      FN:Janet Booles
      NOTE:From the school list
      NOTE:Chair of the residents' association
      UID:ABC-123
      END:VCARD
    CARD
    folded = merge(jane(STORED.sub("NOTE:Met at work\r\n", "")), bare).contact

    assert_equal "From the school list\n\nChair of the residents' association", folded.note
    assert_includes folded.vcard.to_s,
      "NOTE:From the school list\\n\\nChair of the residents' association\r\n"
  end

  # A birthday the contact has none of goes into the model, the split
  # a stored contact is held in.
  def test_a_birthday_the_contact_lacks_comes_into_the_model
    assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), merge.contact.birthday
    refute_includes merge.contact.stored.to_s, "BDAY"
  end

  def test_the_books_own_birthday_stands
    ruth = ProTacts::Birthday.new(month: 4, day: 12)

    assert_equal ruth, merge(jane(birthday: ruth)).contact.birthday
  end

  # What the fold leaves behind is what the card as exported strikes:
  # the name and the note the contact's own stood in for, and nothing
  # the contact already had.
  def test_what_is_left_behind_is_what_differed
    left = merge(jane(birthday: ProTacts::Birthday.new(month: 1, day: 2))).left.map { it.verbatim.chomp }

    assert_equal ["N:Booles;Janet;;;", "FN:Janet Booles", "NOTE:From the school list", "BDAY:1985-04-12"], left
  end

  def test_folding_in_the_same_card_changes_nothing
    same = merge(jane, STORED)

    # The stored card keeps every line but the note's — the entity
    # holds the note, and folding nothing in leaves it standing as
    # the member's own.
    assert_equal STORED.sub("NOTE:Met at work\r\n", ""), same.contact.stored.to_s
    assert_equal "Met at work", same.contact.note
    assert_empty same.left
  end

  ## Which numbers the contact already has

  def with_tel(value) = STORED.sub("TEL;type=CELL:555-010-0100", "TEL:#{value}")

  def arriving_tel(value) = "BEGIN:VCARD\r\nVERSION:3.0\r\nTEL:#{value}\r\nEND:VCARD\r\n"

  # Whether the arriving number came in beside the contact's own.
  def came_in?(ours, theirs)
    merge(jane(with_tel(ours)), arriving_tel(theirs)).contact.phones.length == 2
  end

  # One number in a spelling a card might carry it in: formatted any
  # way, with its country code, behind a trunk zero, or bare.
  def spelling(tc, country, national)
    prefix = tc.draw(sampled_from(["+#{country} ", "00#{country} ", "0", ""]))
    digits = national.chars.flat_map { [it, tc.draw(sampled_from(["", "", " ", "-"]))] }.join
    "#{prefix}#{digits}"
  end

  # Two spellings of one number are one number — a country code or a
  # trunk zero on one side and not the other included — and two
  # countries' numbers that share their last ten digits are two: the
  # one arriving is held exactly when no country code sets it apart
  # from the contact's (docs/plans/2026-09-23-merging-on-import.md).
  # A number held is a number dropped, so the reject direction is the
  # one a loss turns on.
  def test_a_number_is_held_exactly_when_no_country_sets_it_apart
    Hegel.test(test_cases: 1_000) do |tc|
      national = tc.draw(from_regex("[1-9][0-9]{9}", fullmatch: true))
      ours = spelling(tc, tc.draw(sampled_from(%w[1 44 33])), national)
      theirs = spelling(tc, tc.draw(sampled_from(%w[1 44 33])), national)
      country = ->(spelt) { spelt[/\A(?:\+|00)(\d+) /, 1] }
      apart = !country.(ours).nil? && !country.(theirs).nil? && country.(ours) != country.(theirs)

      assert_equal apart, came_in?(ours, theirs), "#{ours.inspect} beside #{theirs.inspect}"
    end
  end

  # A value with no digits is no number, and holds only its own text:
  # `ask mom` is not `n/a`.
  def test_a_value_without_digits_is_held_only_by_its_own_text
    Hegel.test(test_cases: 1_000) do |tc|
      ours, theirs = Array.new(2) { tc.draw(from_regex("[a-z/ ]{0,6}[a-z]", fullmatch: true)) }

      assert_equal ours.casecmp?(theirs), !came_in?(ours, theirs)
    end
  end
end
