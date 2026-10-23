require_relative "../../test_helper"

require "hegel"

require "pro_tacts/admin/card_form"
require "pro_tacts/birthday_line"
require "pro_tacts/contact"
require "pro_tacts/vcard"

# The editor's save over the card it was rendered from, apart from the
# route: test_contacts_pages.rb holds the save through a request, and
# this the one rule a property states better than an example can.
class CardFormTest < Minitest::Test
  include Hegel::Syntax::Methods

  # Value bytes heavy in what a save must not rewrite: escapes the
  # writer would spell another way, separators a client left bare, and
  # whitespace the form's fields strip.
  PIECES = ["Ada", "Lo", " ", ",", "\\,", "\\;", "\\\\", "é"].freeze #: Array[String]

  def value(tc, pieces = PIECES) = tc.draw(arrays(sampled_from(pieces), max_size: 4)).join

  def components(tc, count) = Array.new(tc.draw(integers(min_value: 0, max_value: count))) { value(tc) }.join(";")

  # One content line: a header in any of the spellings a client writes,
  # the value, and perhaps a fold somewhere inside it (RFC 2426 section
  # 2.6), terminated as the rest of the card is.
  def line(tc, names, value, eol)
    text = "#{tc.draw(sampled_from(names))}:#{value}"
    at = tc.draw(optional(integers(min_value: 1, max_value: text.length)))
    text = text.dup.insert(at, "#{eol} ") if at && at < text.length
    "#{text}#{eol}"
  end

  # What the editor renders into each field, as the browser submits it
  # back untouched and the route reads it (Admin::ContactsEdit,
  # Web::Contacts): every box is the reading the form showed, the note
  # textarea's line breaks come back CRLF (the HTML form-submission
  # newline normalization), and the names arrive stripped.
  def untouched(contact)
    own = contact.own
    family, given, additional = contact.name_components || []
    params = {
      "first" => given.to_s, "middle" => additional.to_s, "last" => family.to_s,
      "nickname" => own.nickname.to_s,
      "note" => ProTacts::Admin::CardForm.note_of(own).to_s.gsub("\n", "\r\n"),
      "phone" => rows(own.phones),
      "email" => rows(own.emails),
      "handle" => rows(own.handles),
      "address" => rows(own.addresses),
    }
    organization = ProTacts::Admin::CardForm.organization_of(contact.stored).to_s
    params["organization"] = organization unless organization.empty?
    params
  end

  # Each row's fields as it renders them: its label, empty for none,
  # and its fields.
  def rows(rows) = rows.to_h { [it.line.digest, {"label" => it.label.to_s, **it.fields}] }

  # A save that changed nothing changes no byte, however the card spells
  # what the form shows: parameters and groups the form never modeled,
  # folds, LF terminators, escapes the writer spells another way,
  # whitespace the fields strip, and a legacy card's second NOTE. The
  # surgical save's whole promise (docs/plans/2026-09-05-web-card-editor.md),
  # and a sync's: every rewritten byte moves the etag a client holds.
  def test_an_untouched_save_keeps_every_byte
    Hegel.test(test_cases: 1_000) do |tc|
      eol = tc.draw(sampled_from(["\r\n", "\n"]))
      lines = [
        line(tc, ["N", "N;LANGUAGE=en", "item1.N", "n"], components(tc, 6), eol),
        line(tc, ["FN"], "Ada Lovelace", eol),
        *(tc.draw(booleans) ? [line(tc, ["NICKNAME", "NICKNAME;LANGUAGE=en"], value(tc), eol)] : []),
        *Array.new(tc.draw(integers(min_value: 0, max_value: 2))) {
          line(tc, ["NOTE", "NOTE;LANGUAGE=en"], value(tc, [*PIECES, "\\n", "\\N"]), eol)
        },
        *Array.new(tc.draw(integers(min_value: 0, max_value: 2))) {
          line(tc, ["TEL", "TEL;TYPE=cell", "item2.TEL"], value(tc, [" ", "+1", "555", "0100"]), eol)
        },
        *Array.new(tc.draw(integers(min_value: 0, max_value: 1))) {
          line(tc, ["EMAIL", "EMAIL;TYPE=INTERNET"], value(tc, [" ", "ada", "@", "example.com"]), eol)
        },
        *Array.new(tc.draw(integers(min_value: 0, max_value: 2))) {
          line(tc, ["ADR", "ADR;TYPE=home"], components(tc, 8), eol)
        },
      ]
      stored = ["BEGIN:VCARD#{eol}", "VERSION:3.0#{eol}", *lines, "UID:aiden#{eol}", "END:VCARD#{eol}"].join
      contact = ProTacts::Contact.new(id: "aiden", stored: ProTacts::VCard.new(stored), birthday: nil, inherited: [])
      params = untouched(contact)

      saved = ProTacts::Admin::CardForm.contact_card(
        contact, contact.company?, params["first"].strip, params["middle"].strip, params["last"].strip, params,
      )

      assert_equal stored, saved.to_s
    end
  end

  ## Labels

  # Whatever a row is relabelled to reads back as that word, whichever
  # spelling the save picked for it — a type, an X-ABLabel, Apple's
  # wrapped Other — over lines grouped, labeled, and typed every way a
  # client writes them, the other rows untouched beside it
  # (docs/plans/2026-10-22-a-row-edits-its-label.md). A type word reads
  # in the reader's lowercase, and blank reads as no label.
  def test_a_relabelled_row_reads_back_as_its_label
    Hegel.test(test_cases: 500) do |tc|
      lines = Array.new(tc.draw(integers(min_value: 1, max_value: 3))) { |index|
        group = tc.draw(optional(sampled_from(["item#{index + 1}", "ITEM#{index + 7}"])))
        header = tc.draw(sampled_from(["TEL", "TEL;TYPE=cell", "TEL;type=HOME;type=VOICE;type=pref", "EMAIL;TYPE=INTERNET"]))
        label = group && tc.draw(optional(sampled_from(["Google Voice", "_$!<Other>!$_"])))
        ["#{group && "#{group}."}#{header}:+1-555-010#{index}\r\n", *(label ? ["#{group}.X-ABLabel:#{label}\r\n"] : [])]
      }.flatten
      stored = ["BEGIN:VCARD\r\n", "VERSION:3.0\r\n", "N:Lovelace;Ada;;;\r\n", "FN:Ada Lovelace\r\n", *lines, "UID:aiden\r\n", "END:VCARD\r\n"].join
      contact = ProTacts::Contact.new(id: "aiden", stored: ProTacts::VCard.new(stored), birthday: nil, inherited: [])
      field, rows = tc.draw(sampled_from([["phone", :phones], ["email", :emails]].select { contact.public_send(it[1]).any? }))
      row = tc.draw(sampled_from(contact.public_send(rows)))
      label = tc.draw(sampled_from(["", "home", "Work", "cell", "other", "Google Voice", "home, work", "lab, too"]))
      params = untouched(contact)
      params[field] = params.fetch(field).merge(row.line.digest => {"label" => label, "value" => row.value})

      saved = ProTacts::Admin::CardForm.contact_card(contact, false, "Ada", "", "Lovelace", params)
      after = ProTacts::Contact.new(id: "aiden", stored: saved, birthday: nil, inherited: [])
      relabelled = after.public_send(rows).find { it.value == row.value }

      expected = {"" => nil, "Work" => "work", "other" => "Other"}.fetch(label, label)
      expected.nil? ? assert_nil(relabelled.label) : assert_equal(expected, relabelled.label)
      assert_equal contact.public_send(rows).length, after.public_send(rows).length
      # No label is left naming nothing, and none is lost.
      assert_equal [*after.phones, *after.emails].count(&:label_line), saved.properties.count { it.name.casecmp?("X-ABLabel") }
    end
  end

  ## The birthday row

  # Whatever the birthday row saves in a shape it serves — a month and
  # day, with a year or without — reads back from its line as itself:
  # the next sync cannot change what the editor wrote. The year range is
  # drawn around 1604, the sentinel a served full date would lose its
  # year to (Birthday::NO_YEAR).
  def test_a_saved_birthday_reads_back_from_the_line_it_serves
    field = ->(range) { integers(min_value: range.min, max_value: range.max).map(&:to_s) }
    Hegel.test(test_cases: 1_000) do |tc|
      fields = {
        "year" => tc.draw(optional(one_of(field.(1600..1610), field.(0..9999)))),
        "month" => tc.draw(field.(1..12)),
        "day" => tc.draw(field.(1..31)),
      }
      birthday = ProTacts::Admin::CardForm.birthday(fields)

      line = ProTacts::VCard.new("#{birthday.to_line}\r\n").lines.fetch(0)
      assert_equal birthday, ProTacts::BirthdayLine.read(line).birthday
    end
  end
end
