require_relative "../../test_helper"

require "pro_tacts/contact"
require "pro_tacts/import/merge"

# An arriving card folded into a contact the book already has
# (docs/plans/2026-09-23-merging-on-import.md).
class ImportMergeTest < Minitest::Test
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
    ProTacts::Contact.new(id: "jane", stored: ProTacts::VCard.new(card), birthday:, inherited: [])
  end

  def merge(into = jane, arriving = ARRIVING) = Merge.new(into, ProTacts::VCard.new(arriving))

  # The contact's own card is the base, byte for byte.
  def test_the_contact_keeps_every_line_it_had
    folded = merge.contact.stored.to_s

    STORED.each_line.reject { it.start_with?("END:") }.each do |line|
      assert_includes folded, line
    end
    assert_equal "jane", merge.contact.id
    refute_includes folded, "ABC-123"
  end

  # A number already on the contact, written another way, stays one
  # number; a new one comes in beside it.
  def test_a_number_it_lacks_comes_in_and_one_it_has_does_not
    phones = merge.contact.phones.map(&:value)

    assert_equal ["555-010-0100", "555 010 0199"], phones
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
    assert_equal ["Met at work"], folded.notes.map(&:value)
    assert_equal "JB", folded.nickname
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

    assert_equal STORED, same.contact.stored.to_s
    assert_empty same.left
  end
end
