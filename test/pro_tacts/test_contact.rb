require_relative "../test_helper"
require_relative "../photo_card"

require "base64"
require "digest"

require "pro_tacts/contact"
require "pro_tacts/vcard"

class ContactTest < Minitest::Test
  include Sentry::TestHelper
  include SentryMessages

  CARD = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nEND:VCARD\r\n"

  # A card whose ADR and NOTE arrive in its bytes, as a client's do:
  # the builder below reads them off as components, the way every
  # arrival is read (Contact.of_card), so the accessors answer from
  # the entity's own components and the served card composes them.
  STRUCTURED = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada Lovelace\r\nN:Lovelace;Ada;;;\r\n" \
    "TEL;TYPE=mobile:+1-555-0100\r\nTEL;TYPE=work:+1-555-0199\r\n" \
    "EMAIL;TYPE=home:ada@example.com\r\n" \
    "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
    "NOTE:Countess\\, mathematician.\r\nUID:ada\r\nEND:VCARD\r\n"

  # The card without its ADR and NOTE — the bytes that stay stored
  # once the components are read off.
  STORED = STRUCTURED
    .sub("ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n", "")
    .sub("NOTE:Countess\\, mathematician.\r\n", "")

  ADDRESS = ProTacts::Contact::Address.new(
    po_box: "", extended: "", street: "12 Analytical Way", locality: "London", region: "England",
    postal_code: "NW1 1AA", country: "United Kingdom", label: "home"
  ) #: ProTacts::Contact::Address
  NOTE = "Countess, mathematician." #: String

  # The production shapes (see the class comment): a modeled birthday
  # passes a BDAY-free card beside a Birthday, a fallback case
  # passes a card carrying an unmodeled BDAY beside nil — no stored
  # card ever carries a BDAY the model recomposes — and lending
  # defaults to none, the shape of every contact in no group. Lent
  # addresses and notes are components lent by GROUP, the group a
  # composed row is marked with; a test that needs a second lender
  # passes its own.
  GROUP = ProTacts::Group.new(id: "nous", name: "Booles", label: "Booles", members: ["aiden"]) #: ProTacts::Group

  def lending(group: GROUP, addresses: [], note: nil)
    ProTacts::Contact::Lent.new(
      group:,
      addresses: addresses.each_with_index.map { |address, position|
        ProTacts::Contact::LentAddress.new(position:, address:)
      },
      note:,
    )
  end

  def lent_address
    ProTacts::Contact::Address.new(
      po_box: "", extended: "", street: "7 Calculus Close", locality: "London", region: "England",
      postal_code: "NW1 1AB", country: "United Kingdom", label: "home"
    )
  end

  def lent_line(address = lent_address)
    ProTacts::Contact.address_lines(ProTacts::VCard.new(CARD), address).join("\r\n")
  end

  # A card read into its parts — the entity-less shape, the way
  # every arrival is read (ContactDetails.of_card).
  def contact(bytes = CARD, birthday: nil, lent: [])
    ProTacts::ContactDetails.of_card(card: ProTacts::VCard.new(bytes), birthday:, lent:)
  end

  # A contact whose entity holds the parts directly, over the stored
  # bytes a decompose leaves — the store's shape, id and all.
  def composed(bytes = STORED, id: "aiden", birthday: nil, lent: [], addresses: [ADDRESS], note: NOTE)
    ProTacts::Contact.new(
      id:, stored: ProTacts::VCard.new(bytes), birthday:, addresses:, note:, lent:
    )
  end

  # The decode's refusal reports (see #photo); the transport this pins
  # holds it for the assertions below, and teardown clears it.
  def setup
    setup_sentry
  end

  def teardown
    teardown_sentry_test
  end

  def test_the_etag_hashes_the_card
    assert_equal %("#{Digest::SHA256.hexdigest(CARD)}"), contact.etag
  end

  # The etag hashes the composed card, not the stored one, so it moves
  # when a birthday moves even though the bytes on disk do not.
  def test_the_etag_hashes_the_composed_card
    birthday = ProTacts::Birthday.new(year: 1985, month: 12, day: 10)
    composed = CARD.sub("END:VCARD\r\n", "BDAY:1985-12-10\r\nEND:VCARD\r\n")

    assert_equal %("#{Digest::SHA256.hexdigest(composed)}"), contact(CARD, birthday:).etag
  end

  def test_the_etag_moves_with_the_card
    etag = contact.etag

    assert_equal etag, contact.etag
    refute_equal etag, contact(CARD.sub("Aiden", "Aiden Smith")).etag
  end

  # The same card under two ids is two contacts with the same etag: the
  # etag is about the bytes a client downloads, and the id is not in them.
  def test_the_etag_ignores_the_id
    card = ProTacts::VCard.new(CARD)
    make = ->(id) { ProTacts::Contact.new(id:, stored: card, birthday: nil, addresses: [], note: nil, lent: []) }

    assert_equal make.("aiden").etag, make.("znorth").etag
  end

  def test_ids_outside_the_href_charset_raise
    ["John Smith", "../etc/passwd", "a/b", ""].each do |id|
      error = assert_raises(ArgumentError) { composed(id:) }

      assert_equal "invalid contact id: #{id}", error.message
    end
  end

  def test_uuids_and_slugs_are_ids
    %w[AB12C345-6789-0DEF-1234-567890ABCDEF aiden znorth_2].each do |id|
      assert_equal id, composed(id:).id
    end
  end

  # The parse is lazy so the serving paths never pay it: ctag and the
  # listings build a contact per row without reading structure, and a
  # card that will not parse is still served byte for byte.
  def test_making_a_contact_never_parses_the_card
    assert_equal "aiden", composed("not a vCard at all", addresses: [], note: nil).id
  end

  def test_reads_the_name
    assert_equal "Ada Lovelace", contact(STRUCTURED).name
  end

  def test_inspect_shows_the_id_and_name_and_not_the_card
    bare = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"

    assert_equal %(#<ProTacts::Contact id="aiden" name="Aiden">), composed(bare, addresses: [], note: nil).inspect
  end

  def test_inspect_without_a_name_shows_only_the_id
    bare = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:none\r\nEND:VCARD\r\n"

    assert_equal %(#<ProTacts::Contact id="aiden">), composed(bare, addresses: [], note: nil).inspect
  end

  def test_reads_the_name_components
    assert_equal ["Lovelace", "Ada", nil, nil, nil], contact(STRUCTURED).name_components
  end

  def test_reads_the_nickname
    nicknamed = CARD.sub("FN:Aiden\r\n", "FN:Aiden\r\nNICKNAME:Red\r\n")

    assert_equal "Red", contact(nicknamed).nickname
    assert_nil contact(CARD).nickname
  end

  def test_reads_the_organization
    employed = CARD.sub("FN:Aiden\r\n", "FN:Aiden\r\nORG:Calculus Close Co\r\n")

    assert_equal "Calculus Close Co", contact(employed).organization
    assert_nil contact(CARD).organization
  end

  # X-ABShowAs:COMPANY is Apple's flag for a card shown as a company
  # rather than a person, and it is display's fact alone: a person
  # carries ORG without it.
  def test_reads_whether_the_card_shows_as_a_company
    company = CARD.sub("FN:Aiden\r\n", "FN:Aiden\r\nX-ABShowAs:COMPANY\r\n")
    employed = CARD.sub("FN:Aiden\r\n", "FN:Aiden\r\nORG:Calculus Close Co\r\n")

    assert contact(company).company?
    refute contact(employed).company?
    refute contact(CARD).company?
  end

  def test_values_come_back_unescaped
    escaped = STRUCTURED.sub("FN:Ada Lovelace", "FN:Ada\\, Countess of Lovelace")

    assert_equal "Ada, Countess of Lovelace", contact(escaped).name
  end

  def test_reads_every_phone_with_its_types
    assert_equal [["+1-555-0100", ["mobile"]], ["+1-555-0199", ["work"]]],
      contact(STRUCTURED).phones.map { [it.value, it.types] }
  end

  def test_a_phone_keeps_every_type_but_voice_and_pref
    apple = STRUCTURED.sub("TEL;TYPE=work:", "TEL;TYPE=work,fax;type=VOICE;type=pref:")

    assert_equal %w[work fax], contact(apple).phones.fetch(1).types
  end

  # The label is the `X-ABLabel` sharing the phone's property group — a
  # different line than the row it describes — and the types are a
  # different fact: a row can carry both, and the label wins
  # (docs/plans/2026-09-18-phone-labels.md). A row with no such line
  # reads its types as its label.
  def test_reads_a_phones_label_off_the_line_sharing_its_group
    labeled = STRUCTURED.sub(
      "TEL;TYPE=work:+1-555-0199\r\n",
      "item1.TEL;TYPE=work:+1-555-0199\r\nitem1.X-ABLabel:Google Voice\r\n",
    )

    phones = contact(labeled).phones
    assert_equal "mobile", phones.fetch(0).label
    assert_equal "Google Voice", phones.fetch(1).label
    assert_equal %w[work], phones.fetch(1).types
  end

  # A group name compares without case, so a label spelt `ITEM1.` names
  # `item1.TEL`, as the editor and the import pair them.
  def test_a_phones_label_reads_whatever_case_its_group_is_spelt_in
    labeled = STRUCTURED.sub(
      "TEL;TYPE=work:+1-555-0199\r\n",
      "item1.TEL;TYPE=work:+1-555-0199\r\nITEM1.X-ABLabel:Google Voice\r\n",
    )

    assert_equal "Google Voice", contact(labeled).phones.fetch(1).label
  end

  def test_a_phone_in_a_group_with_no_labeling_line_reads_its_types
    grouped = STRUCTURED.sub("TEL;TYPE=work:", "item2.TEL;TYPE=work:")

    assert_equal %w[mobile work], contact(grouped).phones.map(&:label)
  end

  # Emails read the label beside them as a phone does, and Apple's
  # wrapped vocabulary reads as its word
  # (docs/plans/2026-10-22-a-row-edits-its-label.md). An address's
  # label reads the same way, off the `X-ABLabel` paired to its group
  # when it arrived (Contact.take_addresses).
  def test_an_email_and_an_address_read_their_labels
    labeled = STRUCTURED
      .sub(/^EMAIL[^\r]*/) { "item3.#{it}\r\nitem3.X-ABLabel:_$!<Other>!$_" }
      .sub(/^ADR[^\r]*/) { "item4.#{it}\r\nitem4.X-ABLabel:lab" }

    contact = contact(labeled)
    assert_equal "Other", contact.emails.fetch(0).label
    assert_equal "lab", contact.addresses.fetch(0).label
  end

  # Each phone carries the line it was read from — the address a save
  # names the row by, and the bytes a value-only edit spares. The digest
  # is over the served card's line; composition only inserts the BDAY
  # before END, so it names the stored card's line too.
  def test_every_phone_carries_the_line_it_was_read_from
    with_birthday = ProTacts::Birthday.new(year: 1985, month: 12, day: 10)
    phones = contact(STRUCTURED, birthday: with_birthday).phones

    assert_equal ["TEL;TYPE=mobile:+1-555-0100\r\n", "TEL;TYPE=work:+1-555-0199\r\n"],
      phones.map { it.line.verbatim }
    assert_equal Digest::SHA256.hexdigest("TEL;TYPE=mobile:+1-555-0100\r\n"),
      phones.first.line.digest
  end

  # A line that would not read is a row no form can address. It stays
  # in the card's lines, served from its bytes.
  def test_a_phone_line_that_would_not_read_is_no_phone
    broken = STRUCTURED.sub("TEL;TYPE=mobile:+1-555-0100\r\n", "TEL;=;:+1-555-0100\r\n")

    assert_equal [["+1-555-0199", ["work"]]], contact(broken).phones.map { [it.value, it.types] }
    assert contact(broken).vcard.lines.any? { it.names?("TEL") && it.property.nil? }
  end

  def test_reads_email
    emails = contact(STRUCTURED).emails
    assert_equal 1, emails.length
    assert_equal "ada@example.com", emails.fetch(0).value
    assert_equal ["home"], emails.fetch(0).types
  end

  def test_an_emails_types_skip_internet_and_pref
    apple = STRUCTURED.sub("EMAIL;TYPE=home:", "EMAIL;type=INTERNET;type=pref;type=HOME:")

    assert_equal ["home"], contact(apple).emails.fetch(0).types
  end

  def test_an_email_typed_only_internet_and_pref_has_no_types
    apple = STRUCTURED.sub("EMAIL;TYPE=home:", "EMAIL;type=INTERNET;type=pref:")

    assert_empty contact(apple).emails.fetch(0).types
  end

  def test_every_email_carries_the_line_it_was_read_from
    email = contact(STRUCTURED).emails.fetch(0)

    assert_equal "EMAIL;TYPE=home:ada@example.com\r\n", email.line.verbatim
    assert_equal Digest::SHA256.hexdigest("EMAIL;TYPE=home:ada@example.com\r\n"),
      email.line.digest
  end

  def test_an_email_line_that_would_not_read_is_no_email
    broken = STRUCTURED.sub("EMAIL;TYPE=home:ada@example.com\r\n", "EMAIL;=;:ada@example.com\r\n")

    assert_empty contact(broken).emails
    assert contact(broken).vcard.lines.any? { it.names?("EMAIL") && it.property.nil? }
  end

  def test_reads_a_signal_handle_under_its_service
    signal = STRUCTURED.sub("UID:", "item1.IMPP;X-SERVICE-TYPE=signal:x-apple:ada.42\r\nUID:")
    message = contact(signal).handles.fetch(0)

    assert_equal ["signal", "ada.42", "x-apple"], [message.service, message.value, message.scheme]
    assert_equal "item1.IMPP;X-SERVICE-TYPE=signal:x-apple:ada.42\r\n", message.line.verbatim
  end

  # A service with a scheme of its own keeps it, and one the card
  # names no service for has none.
  def test_a_handle_keeps_its_own_scheme
    xmpp = STRUCTURED.sub("UID:", "IMPP:xmpp:ada@example.com\r\nUID:")

    message = contact(xmpp).handles.fetch(0)
    assert_equal [nil, "ada@example.com", "xmpp"], [message.service, message.value, message.scheme]
  end

  def test_an_impp_with_no_scheme_or_no_handle_is_no_handle
    bare = STRUCTURED.sub("UID:", "IMPP;X-SERVICE-TYPE=signal:ada.42\r\nIMPP:x-apple:\r\nUID:")

    assert_empty contact(bare).handles
  end

  ## The addresses and the note

  # The ADR the card carried reads as the entity's component: seven
  # components, an absent one the empty string, and the label the one
  # word a reader shows — the types, where the line carried no
  # X-ABLabel.
  def test_reads_an_address_as_its_seven_components
    address = contact(STRUCTURED).addresses.fetch(0)

    assert_equal ADDRESS, address
    assert_equal "home", address.label
    assert_nil address.lent_by
  end

  # An ADR with an X-ABLabel paired to its group reads that label:
  # the pairing take_addresses reads, the same one a phone's label
  # uses.
  def test_an_address_label_reads_off_its_pairing
    labeled = STRUCTURED.sub(
      "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n",
      "item1.ADR;type=HOME;type=pref:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
      "item1.X-ABLabel:Summer house\r\n",
    )

    assert_equal "Summer house", contact(labeled).addresses.fetch(0).label
  end

  def test_a_types_only_address_reads_its_types_as_its_label
    postal = contact(STRUCTURED.sub("ADR;TYPE=HOME:", "ADR;type=HOME;type=pref;type=POSTAL:"))

    assert_equal "home, postal", postal.addresses.fetch(0).label
  end

  def test_an_adr_line_that_will_not_read_stays_in_the_card
    broken = STRUCTURED.sub(
      "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n",
      "ADR;=;:;;12 Analytical Way\r\n",
    )
    contact = contact(broken)

    assert_empty contact.addresses
    assert contact.vcard.lines.any? { it.names?("ADR") && it.property.nil? }
  end

  # A blank position and one past the end of the value read the same:
  # neither says anything the card did not.
  def test_address_components_beyond_the_value_are_empty
    short = contact(STRUCTURED.sub(
      "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom",
      "ADR:;;12 Analytical Way",
    ))
    address = short.addresses.fetch(0)

    assert_equal(
      ["", "", "12 Analytical Way", "", "", "", ""],
      [address.po_box, address.extended, address.street, address.locality, address.region, address.postal_code,
       address.country]
    )
  end

  # An ADR blank throughout is no address — the reader's own rule —
  # and an empty NOTE is no note: blank is absent in both directions.
  def test_empty_values_read_as_absent
    empty = STRUCTURED.sub("FN:Ada Lovelace", "FN:")
      .sub("TEL;TYPE=mobile:+1-555-0100", "TEL;TYPE=mobile:")
      .sub("TEL;TYPE=work:+1-555-0199", "TEL;TYPE=work:")
      .sub("EMAIL;TYPE=home:ada@example.com", "EMAIL;TYPE=home:")
      .sub("ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom", "ADR;TYPE=home:;")
      .sub("NOTE:Countess\\, mathematician.", "NOTE:")

    contact = contact(empty)
    assert_nil contact.name
    assert_empty contact.phones
    assert_empty contact.emails
    assert_empty contact.addresses
    assert_nil contact.note
  end

  def test_the_note_is_the_one_the_entity_holds
    assert_equal NOTE, contact(STRUCTURED).note
    assert_nil contact(CARD).note
  end

  def test_the_note_unescapes
    assert_equal "Countess, mathematician.", contact(STRUCTURED).note
  end

  # The birthday is the model held beside the card, not a parse of
  # the card it composes into — the reader returns the store's fact.
  def test_the_birthday_is_the_one_held_beside_the_card
    birthday = ProTacts::Birthday.new(year: 1985, month: 12, day: 10)

    assert_equal birthday, contact(STRUCTURED, birthday:).birthday
  end

  # The served card composes the entity's components and the birthday
  # immediately before END:VCARD — the card's own lines, then its
  # addresses, then its note, then the birthday — so the card a client
  # downloads carries everything in one fixed order.
  def test_the_served_card_composes_the_components_in
    birthday = ProTacts::Birthday.new(year: 1985, month: 12, day: 10)
    assert_equal(
      STORED.sub(
        "END:VCARD\r\n",
        "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
        "NOTE:Countess\\, mathematician.\r\n" \
        "BDAY:1985-12-10\r\nEND:VCARD\r\n",
      ),
      composed(birthday:).vcard.to_s,
    )
  end

  # A birthday with no wire form — the shapes no client renders —
  # composes nothing; the components compose as they would without it.
  def test_a_birthday_with_no_wire_form_composes_the_components_alone
    year_alone = ProTacts::Birthday.new(year: 1985)

    assert_equal(
      STORED.sub(
        "END:VCARD\r\n",
        "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
        "NOTE:Countess\\, mathematician.\r\nEND:VCARD\r\n",
      ),
      composed(birthday: year_alone).vcard.to_s,
    )
  end

  # A BDAY in a spelling the model does not recompose stays in the card
  # verbatim; the reader answers nil over it, and showing it as stored
  # is the substrate's job (Format.birthday).
  def test_an_unmodeled_birthday_spelling_reads_nil
    unmodeled = STRUCTURED.sub("END:VCARD\r\n", "BDAY:not-a-date\r\nEND:VCARD\r\n")

    assert_nil contact(unmodeled).birthday
  end

  ## The lent components

  # The group's addresses land between the member's own and the
  # composed note and birthday, so the card a client downloads carries
  # everything in one fixed order.
  def test_the_served_card_composes_lent_addresses_before_the_note_and_birthday
    birthday = ProTacts::Birthday.new(year: 1985, month: 12, day: 10)
    lent = [lending(addresses: [lent_address], note: "Gate code 1854.")]
    assert_equal(
      STORED.sub(
        "END:VCARD\r\n",
        "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
        "ADR;TYPE=HOME:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom\r\n" \
        "NOTE:Countess\\, mathematician.\\n\\nShared · Booles:\\nGate code 1854.\r\n" \
        "BDAY:1985-12-10\r\nEND:VCARD\r\n",
      ),
      composed(birthday:, lent:).vcard.to_s,
    )
  end

  # A labeled lent address composes under an `item` group of its own,
  # numbered past every group the stored card names, so a lent label
  # can never pair with a member's own line.
  def test_a_labeled_lent_address_composes_under_its_own_group
    labelled = lent_address.with(label: "summer house")
    lent = [lending(addresses: [labelled])]
    assert_equal(
      STORED.sub(
        "END:VCARD\r\n",
        "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
        "item1.ADR:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom\r\n" \
        "item1.X-ABLabel:summer house\r\n" \
        "NOTE:Countess\\, mathematician.\r\nEND:VCARD\r\n",
      ),
      composed(lent:).vcard.to_s,
    )
  end

  # An empty lending is insert's own no-op.
  def test_a_contact_in_no_group_serves_its_stored_bytes_and_etag
    assert_equal CARD, contact(CARD).vcard.to_s
    assert_equal ProTacts::Contact.etag_for(ProTacts::VCard.new(CARD)), contact(CARD).etag
  end

  # The served addresses are the entity's own first and then each
  # group's, each carrying the group that lends it — the row a screen
  # marks as shared asks it per component.
  def test_an_address_names_the_group_that_lends_it
    contact = composed(lent: [lending(addresses: [lent_address])])
    addresses = contact.served_addresses

    assert_equal 2, addresses.size
    assert_nil addresses.fetch(0).lent_by
    assert_equal GROUP, addresses.fetch(1).lent_by
  end

  # A lent NOTE composes into the member's own as one value — the
  # served card carries one NOTE, not two, because macOS keeps only
  # the last of two and a PUT would store the truncation
  # (docs/plans/2026-09-25-one-note-per-contact.md). The member's own
  # text first, the group's as a section after it.
  def test_a_lent_note_composes_into_the_members_own
    lent = [lending(note: "Gate code 1854.")]

    assert_equal(
      STORED.sub(
        "END:VCARD\r\n",
        "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
        "NOTE:Countess\\, mathematician.\\n\\nShared · Booles:\\nGate code 1854.\r\nEND:VCARD\r\n",
      ),
      composed(lent:).vcard.to_s,
    )
  end

  # A member with no note of its own serves the section alone.
  def test_a_member_with_no_note_of_its_own_serves_the_section_alone
    lent = [lending(note: "Gate code 1854.")]

    assert_equal(
      CARD.sub("END:VCARD\r\n", "NOTE:Shared · Booles:\\nGate code 1854.\r\nEND:VCARD\r\n"),
      contact(CARD, lent:).vcard.to_s,
    )
  end

  # Nothing lent that is a note, and the member's own note serves as
  # the model holds it; what else the group lends composes as lines
  # around it.
  def test_a_contact_whose_groups_lend_no_note_serves_its_own_note
    assert_equal(
      STORED.sub(
        "END:VCARD\r\n",
        "ADR;TYPE=HOME:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
        "ADR;TYPE=HOME:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom\r\n" \
        "NOTE:Countess\\, mathematician.\r\nEND:VCARD\r\n",
      ),
      composed(lent: [lending(addresses: [lent_address])]).vcard.to_s,
    )
  end

  # Own: the same contact with nothing its groups lend it — the
  # editor's subject, holding the member's own components.
  def test_own_holds_the_members_components_without_the_lent_ones
    contact = composed(lent: [lending(addresses: [lent_address], note: "Gate code.")])

    assert_equal [ADDRESS], contact.own.addresses
    assert_equal NOTE, contact.own.note
    assert_empty contact.own.lent
    assert_equal GROUP, contact.served_addresses.fetch(1).lent_by
  end

  # With: the same contact over another card and birthday, still lent
  # what its groups lend it — the import's proposal, the card read
  # back into components the way a save will write them.
  # With: the same contact over another card and birthday and
  # components, still lent what its groups lend it — the import's
  # proposal, holding what the fold took in behind the member's own.
  def test_with_takes_the_proposal_whole
    contact = composed(lent: [lending(addresses: [lent_address])])
    arrival = ProTacts::VCard.new(STORED.sub("FN:Ada Lovelace", "Ada King"))
    address = ADDRESS.with(street: "14 Analytical Way")
    with = contact.with(stored: arrival, birthday: nil, addresses: [address], note: "Countess of Lovelace.")

    assert_equal STORED.sub("FN:Ada Lovelace", "Ada King"), with.stored.to_s
    assert_equal [address], with.addresses
    assert_equal "Countess of Lovelace.", with.note
    assert_equal contact.lent, with.lent
  end

  def test_properties_are_the_parsed_card
    properties = composed.properties

    assert_equal "BEGIN", properties.fetch(0).name
    assert properties.any? { it.name.casecmp?("TEL") }
  end

  def test_attributes_with_no_data_are_nil_or_empty
    bare = contact("BEGIN:VCARD\r\nVERSION:3.0\r\nUID:bare\r\nEND:VCARD\r\n")

    assert_nil bare.name
    assert_nil bare.name_components
    assert_nil bare.nickname
    assert_empty bare.phones
    assert_empty bare.emails
    assert_empty bare.addresses
    assert_nil bare.birthday
    assert_nil bare.note
  end

  # A card that will not read is still a contact: the bytes are what
  # gets served, and no accessor has a repair to offer for a line the
  # parser cannot read. The accessors answer from the lines that read
  # and say nothing about the rest.
  def test_a_card_that_will_not_parse_answers_from_what_read
    assert_empty contact("not a vCard at all").phones
    assert_empty contact("not a vCard at all").properties
    assert_equal "Aiden", contact("FN:Aiden\r\nTEL;HOME:+1-555-1234\r\n").name
  end

  ## Photos

  # The picture the card carries, decoded: PHOTO's base64 payload as
  # bytes, with the mime type read off the decoded bytes themselves —
  # magic bytes cannot mislabel what they are — rather than the TYPE
  # parameter. The synthetic payload carries the JPEG signature the
  # builder gives every image.
  def test_a_photo_reads_decoded_with_a_sniffed_type
    photo = contact(PhotoCard.photo("aiden", bytes: 64)).photo

    assert_equal "image/jpeg", photo.mime_type
    assert_equal PhotoCard.image(64), photo.bytes
  end

  # The sniff's other rows: a picture named PNG or GIF reads as what
  # its bytes are, whatever the TYPE parameter said.
  def test_png_and_gif_payloads_sniff_to_their_types
    png = CARD.sub("FN:Aiden\r\n", photo_property("\x89PNG\r\n\x1A\nx"))
    gif = CARD.sub("FN:Aiden\r\n", photo_property("GIF89ax"))

    assert_equal "image/png", contact(png).photo&.mime_type
    assert_equal "image/gif", contact(gif).photo&.mime_type
  end

  def test_a_card_without_a_photo_has_none
    assert_nil contact.photo

    # The one nil that stays quiet: no PHOTO is no news.
    assert_empty sentry_events
  end

  # A URI-form PHOTO never reaches the sniff: a URI's ":" is not in
  # base64's alphabet and the strict decode refuses the value. Same
  # nil for a payload that is not an image a browser can show — the
  # initials an avatar falls back to, an ordinary absence.
  def test_a_photo_that_is_not_showable_has_none
    uri = CARD.sub("FN:Aiden\r\n", "PHOTO;VALUE=uri:https://example.com/me.jpg\r\n")
    undecodable = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:not base64!!\r\n")
    not_an_image = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:#{Base64.strict_encode64("text, not an image")}\r\n")

    assert_nil contact(uri).photo
    assert_nil contact(undecodable).photo
    assert_nil contact(not_an_image).photo
  end

  # The departure from the accessor's ordinary nils: a value the
  # strict decoder refuses reports on its way to nil — warning-grade,
  # bad-input level, no card content — so a PHOTO this server cannot
  # read is news rather than initials with no why.
  def test_an_undecodable_photo_reports_the_refusal
    undecodable = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:not base64!!\r\n")

    assert_nil contact(undecodable).photo

    assert_equal 1, sentry_events.length
    event = sentry_events.fetch(0)
    assert_equal :warning, event.level
    assert_equal "ArgumentError", event.exception.values.first.type
  end

  # The sniff's nil reports too, a message rather than an exception —
  # there is no error to name, only bytes whose format the signature
  # list does not know, and the message is the record that they
  # arrived.
  def test_a_photo_of_no_known_format_warns
    unknown = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:#{Base64.strict_encode64("RIFF____WEBP")}\r\n")

    assert_nil contact(unknown).photo

    assert_equal 1, sentry_messages.length
    assert_match(/PHOTO decoded to no image format/, sentry_messages.fetch(0))
  end

  # The avatar's question, answered from the first bytes: the same
  # yes and no as #photo for a picture and for none, and a yes for a
  # payload broken past its signature, which only the full decode can
  # see. Nothing reports on the way, the photo route's decode being
  # where a broken picture is news.
  def test_photo_asks_only_the_payloads_first_bytes
    broken_tail = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:#{Base64.strict_encode64("\xFF\xD8\xFF\xE0" + "x" * 20)}!!\r\n")
    not_an_image = CARD.sub("FN:Aiden\r\n", photo_property("text, not an image"))
    undecodable = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:not base64!!\r\n")

    assert_predicate contact(PhotoCard.photo("aiden", bytes: 64)), :photo?
    assert_predicate contact(broken_tail), :photo?
    refute_predicate contact, :photo?
    refute_predicate contact(not_an_image), :photo?
    refute_predicate contact(undecodable), :photo?
    assert_empty sentry_events
  end

  # One PHOTO property carrying a PNG payload, for the sniff's rows.
  def photo_property(payload)
    "PHOTO;ENCODING=b;TYPE=JPEG:#{Base64.strict_encode64(payload)}\r\n"
  end
end
