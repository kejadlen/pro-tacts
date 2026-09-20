require_relative "../../test_helper"

require "json"
require "pathname"
require "tmpdir"

require "pro_tacts/import/macos"
require "pro_tacts/import/plan"

class ImportMacosTest < Minitest::Test
  Macos = ProTacts::Import::Macos

  Card = ProTacts::Import::Card

  CREATED_AT = Time.utc(2026, 9, 16, 18, 4, 12)
  NAME = ["N:Lovelace;Ada;;;", "FN:Ada Lovelace"].freeze
  GROUPS = ["sync:*", "import-20260916T180412Z"].freeze

  def record(identifier, name: NAME, lines: [], note: nil, image: nil)
    {
      "identifier" => identifier,
      "vcard" => ["BEGIN:VCARD", "VERSION:3.0", *name, *lines, "END:VCARD", ""].join("\r\n"),
      "contact" => {"identifier" => identifier, "imageData" => image},
      "note" => note
    }
  end

  def in_tmpdir
    Dir.mktmpdir { yield Pathname.new(it) / "plan" }
  end

  def test_a_named_card_is_planned_under_a_minted_id
    in_tmpdir do |dir|
      plan = Macos.plan(dir, [record("A:ABPerson")], created_at: CREATED_AT)

      assert_equal 1, plan.contacts.size
      contact = plan.contacts.first
      assert_match(/\A[k-z]{12}\z/, contact.id)
      assert_equal "A:ABPerson", contact.source_id
      card = plan.card(contact.id)
      assert_equal ["Ada", "Lovelace", nil, nil, [], [], [], GROUPS],
        [card.first, card.last, card.nickname, card.birthday, card.phones, card.emails, card.addresses, card.groups]
    end
  end

  def test_the_card_holds_the_source_it_was_read_from
    in_tmpdir do |dir|
      read = record("A:ABPerson")
      read["contact"] = read.fetch("contact").merge("givenName" => "Ada")
      plan = Macos.plan(dir, [read], created_at: CREATED_AT)

      source = plan.card(plan.contacts.first.id).source
      assert_equal read.fetch("vcard"), source.fetch("vcard")
      assert_equal "A:ABPerson", source.fetch("identifier")
      assert_nil source.fetch("note")
      assert_equal read.fetch("contact"), source.fetch("contact")
    end
  end

  def test_every_unknown_field_is_named_and_no_plan_is_written
    in_tmpdir do |dir|
      records = [
        record("A:ABPerson", lines: ["ROLE:Analyst", "EMAIL:ada@example.com"], note: "Analyst."),
        record("B:ABPerson", lines: ["EMAIL:mary@example.com"], image: "/9j/")
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          EMAIL: 2
            A:ABPerson: "EMAIL:ada@example.com"
            B:ABPerson: "EMAIL:mary@example.com"
          ROLE: 1
            A:ABPerson: "ROLE:Analyst"
      MESSAGE
      refute dir.exist?
    end
  end

  def test_examples_are_distinct_unfolded_and_cut_short
    in_tmpdir do |dir|
      records = %w[A B C D].map { record("#{it}:ABPerson", lines: ["PHOTO;ENCODING=b:#{"A" * 60}\r\n #{"A" * 60}"]) }
      records << record("E:ABPerson", lines: ["NOTE:one\\ntwo"], note: "one\ntwo")
      records << record("F:ABPerson", lines: ["NOTE:one\\ntwo"])

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          NOTE: 2
            E:ABPerson: "NOTE:one\\\\ntwo"
          PHOTO: 4
            A:ABPerson: "PHOTO;ENCODING=b:#{"A" * 83}… (137 characters)"
      MESSAGE
    end
  end

  def test_a_cell_number_is_a_phone
    in_tmpdir do |dir|
      lines = ["TEL;type=CELL;type=VOICE;type=pref:+12532189075", "TEL;type=CELL;type=VOICE;type=pref:+12532189076"]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal [{"number" => "+12532189075"}, {"number" => "+12532189076"}], plan.card(plan.contacts.first.id).phones
    end
  end

  def test_a_name_is_read_unescaped
    in_tmpdir do |dir|
      plan = Macos.plan(dir, [record("A:ABPerson", name: ["N:O\\,Brien;Ada;;;", "FN:Ada O\\,Brien"])], created_at: CREATED_AT)

      assert_equal "O,Brien", plan.card(plan.contacts.first.id).last
    end
  end

  def test_an_address_a_birthday_and_the_emails_are_fields
    in_tmpdir do |dir|
      lines = [
        "item1.ADR;type=HOME;type=pref:;;12 Marylebone Rd;London;;NW1 5LS;England",
        "BDAY:1815-12-10",
        "EMAIL;type=INTERNET;type=HOME:ada@example.com",
        "EMAIL;type=INTERNET;type=WORK;type=pref:ada@analytical.example",
        "EMAIL;type=INTERNET:ada@lovelace.example"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      card = plan.card(plan.contacts.first.id)
      assert_equal "1815-12-10", card.birthday
      assert_equal ["ada@example.com", "ada@analytical.example", "ada@lovelace.example"], card.emails
      assert_equal [{"street" => "12 Marylebone Rd", "locality" => "London", "postal_code" => "NW1 5LS", "country" => "England"}], card.addresses
    end
  end

  # An address is carried under its group already; an email labelled in
  # Contacts is the same shape, and its label goes where an address's
  # does. Nothing is lost that an unlabelled row would have kept: an
  # imported EMAIL line carries no type either (Admin::CardForm).
  def test_a_labelled_email_is_carried_and_its_label_dropped
    in_tmpdir do |dir|
      lines = [
        "item1.EMAIL;type=INTERNET;type=pref:ada@example.com",
        "item1.X-ABLabel:_$!<Home>!$_"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal ["ada@example.com"], plan.card(plan.contacts.first.id).emails
    end
  end

  # Contacts writes an address ungrouped when nothing labels it, and
  # grouped when something does; both are the one field.
  def test_an_ungrouped_address_is_an_address
    in_tmpdir do |dir|
      lines = ["ADR;type=HOME:;;12 Marylebone Rd;London;;NW1 5LS;England"]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal [{"street" => "12 Marylebone Rd", "locality" => "London", "postal_code" => "NW1 5LS", "country" => "England"}],
        plan.card(plan.contacts.first.id).addresses
    end
  end

  # The editor's address rows carry no type, so the work address would
  # land as an unmarked second one beside the home; the home is the one
  # the fields can hold, and the work stays in the source.
  def test_a_work_address_is_dropped_and_the_home_carried
    in_tmpdir do |dir|
      lines = [
        "ADR;type=HOME:;;12 Marylebone Rd;London;;NW1 5LS;",
        "ADR;type=WORK:;;17 Clerkenwell Rd;London;;EC1R 5BQ;",
        "item3.ADR;type=WORK;type=pref:;;4 Russell Sq;London;;WC1B 4JP;"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal [{"street" => "12 Marylebone Rd", "locality" => "London", "postal_code" => "NW1 5LS"}],
        plan.card(plan.contacts.first.id).addresses
    end
  end

  def test_a_work_address_alone_is_no_address_at_all
    in_tmpdir do |dir|
      lines = ["item1.ADR;type=WORK:;;17 Clerkenwell Rd;London;;EC1R 5BQ;"]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_empty plan.card(plan.contacts.first.id).addresses
    end
  end

  # A work number is a number, and one Contacts labelled is too — the
  # label riding the annotation rail to the row it names, where a
  # labelled email's and address's are still dropped
  # (docs/plans/2026-09-18-phone-labels.md).
  def test_a_work_number_and_a_labelled_one_are_phones
    in_tmpdir do |dir|
      lines = [
        "TEL;type=WORK;type=VOICE:+1 203-536-3941",
        "item1.TEL;type=pref:(206) 651-4359",
        "item1.X-ABLabel:school"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal [{"number" => "+1 203-536-3941"}, {"number" => "(206) 651-4359", "label" => "school"}],
        plan.card(plan.contacts.first.id).phones
    end
  end

  # Apple's own label vocabulary arrives wrapped, and a phone's label
  # unwraps the way a related name's does.
  def test_a_phone_with_an_apple_label_unwraps_it
    in_tmpdir do |dir|
      lines = [
        "item1.TEL;type=pref:+12532189075",
        "item1.X-ABLabel:_$!<Other>!$_"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal [{"number" => "+12532189075", "label" => "Other"}], plan.card(plan.contacts.first.id).phones
    end
  end

  # The main number, with the rank Contacts gives it: `type=pref` names
  # no kind and comes off the form, so the allowlist holds the spelling
  # without it and both arrive under the one entry.
  def test_a_main_number_is_a_phone_ranked_or_not
    in_tmpdir do |dir|
      records = [
        record("A:ABPerson", lines: ["TEL;type=MAIN;type=pref:+12532189075"]),
        record("B:ABPerson", lines: ["TEL;type=MAIN:(206) 651-4359"])
      ]
      plan = Macos.plan(dir, records, created_at: CREATED_AT)

      assert_equal [[{"number" => "+12532189075"}], [{"number" => "(206) 651-4359"}]],
        plan.contacts.map { plan.card(it.id).phones }
    end
  end

  # Where someone works has no field in this address book; the source
  # keeps the lines the card drops.
  def test_a_job_title_and_an_organization_are_dropped
    in_tmpdir do |dir|
      lines = ["TITLE:Countess of Lovelace", "ORG:Analytical Engine Co.;"]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      card = plan.card(plan.contacts.first.id)
      assert_equal [[], [], []], [card.phones, card.emails, card.addresses]
      assert_includes card.source.fetch("vcard"), "TITLE:Countess of Lovelace"
      assert_includes card.source.fetch("vcard"), "ORG:Analytical Engine Co.;"
    end
  end

  def test_a_second_address_under_another_item_number_is_one_form
    in_tmpdir do |dir|
      lines = [
        "item1.ADR;type=HOME;type=pref:;;12 Marylebone Rd;London;;;",
        "item2.ADR;type=HOME:;;Ockham Park;Surrey;;;"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal ["12 Marylebone Rd", "Ockham Park"], plan.card(plan.contacts.first.id).addresses.map { it.fetch("street") }
    end
  end

  def test_every_kind_of_number_is_a_phone_and_an_empty_row_is_not
    in_tmpdir do |dir|
      lines = [
        "TEL;type=pref:+1 203-536-3941",
        "TEL;type=HOME;type=VOICE;type=pref:(206) 651-4359",
        "TEL;type=IPHONE;type=CELL;type=VOICE:",
        "TEL;type=CELL;type=VOICE:+12532189075",
        "TEL;type=OTHER;type=VOICE:+1 (425) 707-1712"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal [{"number" => "+1 203-536-3941"}, {"number" => "(206) 651-4359"}, {"number" => "+12532189075"},
        {"number" => "+1 (425) 707-1712"}], plan.card(plan.contacts.first.id).phones
    end
  end

  def test_a_nickname_is_a_field_and_an_instant_message_address_is_dropped
    in_tmpdir do |dir|
      lines = ["NICKNAME:The Countess", "IMPP;X-SERVICE-TYPE=Skype;type=HOME;type=pref:skype:ada"]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal "The Countess", plan.card(plan.contacts.first.id).nickname
    end
  end

  def test_the_note_and_the_picture_are_fields
    in_tmpdir do |dir|
      jpeg = ["\xFF\xD8\xFFhello".b].pack("m0")
      plan = Macos.plan(dir, [record("A:ABPerson", note: "Analyst.", image: jpeg)], created_at: CREATED_AT)

      card = plan.card(plan.contacts.first.id)
      assert_equal "Analyst.", card.note
      assert card.photo
      assert_equal "image/jpeg", card.contact(plan.contacts.first.id).photo.mime_type
    end
  end

  def test_the_fields_this_address_book_does_not_have_are_dropped
    in_tmpdir do |dir|
      lines = [
        "IMPP;X-SERVICE-TYPE=Skype;type=HOME;type=pref:skype:ada",
        "X-SOCIALPROFILE;type=twitter:https://twitter.com/ada",
        "item1.X-APPLE-SUBADMINISTRATIVEAREA:Middlesex",
        "item1.X-APPLE-SUBLOCALITY:Marylebone",
        "X-AIM;type=HOME;type=pref:ada",
        "item2.URL;type=pref:https://example.com",
        "item2.X-ABLabel:_$!<HomePage>!$_",
        "item2.X-ABADR:us"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal "Ada Lovelace", plan.card(plan.contacts.first.id).contact("kmnuqmzxylru").name
    end
  end

  def test_a_related_name_is_written_under_the_note
    in_tmpdir do |dir|
      lines = [
        "item2.X-ABRELATEDNAMES;type=pref:Sylvia Lovelace",
        "item2.X-ABLabel:_$!<Spouse>!$_",
        "item3.X-ABRELATEDNAMES:Byron",
        "item3.X-ABLabel:the poet",
        "item4.URL;type=pref:https://example.com",
        "item4.X-ABLabel:_$!<HomePage>!$_"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:, note: "Analyst.")], created_at: CREATED_AT)

      assert_equal "Analyst.\n\nSpouse: Sylvia Lovelace\nthe poet: Byron", plan.card(plan.contacts.first.id).note
    end
  end

  def test_a_related_name_is_the_whole_note_of_a_contact_with_none
    in_tmpdir do |dir|
      lines = ["item2.X-ABRELATEDNAMES;type=pref:Sylvia", "item2.X-ABLabel:_$!<Spouse>!$_"]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal "Spouse: Sylvia", plan.card(plan.contacts.first.id).note
    end
  end

  def test_a_maiden_name_is_written_under_the_note
    in_tmpdir do |dir|
      lines = [
        "X-MAIDENNAME:Byron",
        "item2.X-ABRELATEDNAMES;type=pref:Sylvia Lovelace",
        "item2.X-ABLabel:_$!<Spouse>!$_"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:, note: "Analyst.")], created_at: CREATED_AT)

      assert_equal "Analyst.\n\nMaiden name: Byron\nSpouse: Sylvia Lovelace", plan.card(plan.contacts.first.id).note
    end
  end

  def test_a_maiden_name_is_the_whole_note_of_a_contact_with_none
    in_tmpdir do |dir|
      plan = Macos.plan(dir, [record("A:ABPerson", lines: ["X-MAIDENNAME:Byron"])], created_at: CREATED_AT)

      assert_equal "Maiden name: Byron", plan.card(plan.contacts.first.id).note
    end
  end

  def test_a_second_maiden_name_is_refused
    in_tmpdir do |dir|
      records = [record("A:ABPerson", lines: ["X-MAIDENNAME:Byron", "X-MAIDENNAME:King"])]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_includes error.message, "X-MAIDENNAME lines: 2: 1"
    end
  end

  def test_a_maiden_name_in_any_other_form_is_refused_under_that_form
    in_tmpdir do |dir|
      records = [record("A:ABPerson", lines: ["item1.X-MAIDENNAME:Byron"])]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_includes error.message, "item#.X-MAIDENNAME: 1"
    end
  end

  def test_an_annotation_with_no_line_to_annotate_is_refused
    in_tmpdir do |dir|
      records = [record("A:ABPerson", lines: ["item5.X-ABADR:us", "X-ABLabel:_$!<Spouse>!$_"])]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          X-ABADR: 1
            A:ABPerson: "item5.X-ABADR:us"
          X-ABLABEL: 1
            A:ABPerson: "X-ABLabel:_$!<Spouse>!$_"
      MESSAGE
    end
  end

  def test_a_second_nickname_is_refused
    in_tmpdir do |dir|
      records = [record("A:ABPerson", lines: ["NICKNAME:The Countess", "NICKNAME:Ada"])]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_includes error.message, "NICKNAME lines: 2: 1"
    end
  end

  def test_a_value_no_field_can_hold_is_refused
    in_tmpdir do |dir|
      records = [
        record("A:ABPerson", lines: ["BDAY:--12-10"]),
        record("C:ABPerson", lines: ["item1.ADR;type=HOME:P.O. Box 4;;;London;;;"]),
        record("D:ABPerson", lines: ["item1.ADR;type=HOME:;;Ockham Park;Surrey"]),
        record("E:ABPerson", lines: ["BDAY:1815-12-10", "BDAY:1815-12-11"])
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          ADR value: 2
            C:ABPerson: "item1.ADR;type=HOME:P.O. Box 4;;;London;;;"
            D:ABPerson: "item1.ADR;type=HOME:;;Ockham Park;Surrey"
          BDAY lines: 2: 1
            E:ABPerson: "BDAY:1815-12-10 / BDAY:1815-12-11"
          BDAY value: 1
            A:ABPerson: "BDAY:--12-10"
      MESSAGE
    end
  end

  # An address book has no field for a directory name, and Exchange
  # writes one into an EMAIL. It leaves with the IMPPs rather than
  # stopping the plan, and the source keeps the line.
  def test_an_email_that_is_not_an_address_is_dropped
    in_tmpdir do |dir|
      lines = [
        "item2.EMAIL;type=INTERNET:/O=microsoft/OU=northamerica/cn=Recipients/cn=algersha",
        "EMAIL;type=INTERNET:ada@example.com"
      ]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      card = plan.card(plan.contacts.first.id)
      assert_equal ["ada@example.com"], card.emails
      assert_includes card.source.fetch("vcard"), "cn=algersha"
    end
  end

  # An extension is part of the number as a person typed it.
  def test_a_number_carries_the_extension_written_after_it
    in_tmpdir do |dir|
      lines = ["TEL;type=WORK;type=VOICE:+1 (425) 707-1712 X71712"]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal [{"number" => "+1 (425) 707-1712 X71712"}], plan.card(plan.contacts.first.id).phones
    end
  end

  def test_a_name_beyond_first_and_last_is_refused
    in_tmpdir do |dir|
      records = [
        record("A:ABPerson", name: ["N:Lovelace;Ada;Augusta;;", "FN:Ada Lovelace"]),
        record("B:ABPerson", name: ["N:Lovelace;Ada;;;", "FN:Countess Ada Lovelace"]),
        record("C:ABPerson", name: ["FN:Ada Lovelace"]),
        record("D:ABPerson", name: ["N:;;;;", "FN:"])
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          FN other than first and last: 2
            B:ABPerson: "FN:Countess Ada Lovelace"
            C:ABPerson: "FN:Ada Lovelace"
          N beyond first and last: 1
            A:ABPerson: "N:Lovelace;Ada;Augusta;;"
          N lines: 0: 1
            C:ABPerson: ""
          no name: 1
            D:ABPerson: "N:;;;;"
      MESSAGE
    end
  end

  def test_an_apple_prodid_is_dropped
    in_tmpdir do |dir|
      plan = Macos.plan(dir, [record("A:ABPerson", lines: ["PRODID:-//Apple Inc.//macOS 26.0//EN"])], created_at: CREATED_AT)

      card = plan.card(plan.contacts.first.id)
      assert_equal [[], [], []], [card.phones, card.emails, card.addresses]
    end
  end

  def test_any_other_prodid_is_refused
    in_tmpdir do |dir|
      records = [
        record("A:ABPerson", lines: ["PRODID:-//Monica//EN"]),
        record("B:ABPerson", lines: ["PRODID;VALUE=text:-//Apple Inc.//macOS 26.0//EN"])
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          PRODID value: 1
            A:ABPerson: "PRODID:-//Monica//EN"
          PRODID;VALUE=text: 1
            B:ABPerson: "PRODID;VALUE=text:-//Apple Inc.//macOS 26.0//EN"
      MESSAGE
    end
  end

  def test_a_line_in_any_other_form_is_refused_under_that_form
    in_tmpdir do |dir|
      records = [
        record("C:ABPerson", lines: ["item1.TEL;type=CELL;type=VOICE;type=pref:+12532189075"]),
        record("D:ABPerson", lines: ["TEL;type=CELL;type=VOICE;type=pref:ext. 4"]),
        record("E:ABPerson", name: ["N:Lovelace;Ada;;;", "FN;CHARSET=utf-8:Ada Lovelace"])
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          FN lines: 0: 1
            E:ABPerson: ""
          FN;CHARSET=utf-8: 1
            E:ABPerson: "FN;CHARSET=utf-8:Ada Lovelace"
          TEL value: 1
            D:ABPerson: "TEL;type=CELL;type=VOICE;type=pref:ext. 4"
          item#.TEL;type=CELL;type=VOICE: 1
            C:ABPerson: "item1.TEL;type=CELL;type=VOICE;type=pref:+12532189075"
      MESSAGE
    end
  end

  def test_a_card_that_is_not_version_3_is_refused
    in_tmpdir do |dir|
      source = record("A:ABPerson")
      source["vcard"] = source.fetch("vcard").sub("VERSION:3.0", "VERSION:4.0")

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, [source], created_at: CREATED_AT) }

      assert_includes error.message, "VERSION:4.0: 1"
    end
  end
end
