require "pro_tacts/birthday"
require "pro_tacts/contact"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  module Admin
    # The admin editors' forms read back into cards: the fields
    # ContactsEdit and GroupsEdit render, spliced into the card each was
    # rendered from, and the create dialog's two names made into a new
    # one. The surgical save — the hazard it exists to remove, the
    # blank-equals-absent rule, and why REV is left alone — is
    # docs/plans/2026-09-05-web-card-editor.md.
    #
    # Not a view, unlike its neighbours, so the Steepfile checks it.
    module CardForm
      # A created contact's card: the envelope RFC 2426 section 4
      # requires — BEGIN, VERSION, and the N and FN that section makes
      # mandatory — plus the UID this server's id model is (see
      # Contact). Nothing else: a created card has no prior octets to
      # preserve, and every other property arrives by editing the
      # record later. The names escape, because a name is text — a
      # comma or semicolon in one must not read as structure (RFC 2426
      # section 2.4.2).
      #: (String id, String first, String middle, String last) -> VCard
      def self.new_card(id, first, middle, last)
        VCard.new(
          "BEGIN:VCARD\r\nVERSION:3.0\r\n" \
            "N:#{VCard.escape(last)};#{VCard.escape(first)};#{VCard.escape(middle)};;\r\n" \
            "FN:#{VCard.escape(display_name(first, middle, last))}\r\n" \
            "UID:#{id}\r\n" \
            "END:VCARD\r\n",
        )
      end

      # Whether the save writes a company card: the editor's Company
      # box, which submits "1" checked and the hidden "0" before it
      # otherwise. A POST carrying neither keeps what the card is
      # (Contact#company?), so no other form's save can switch one.
      #: (Contact contact, Hash[String, untyped] params) -> bool
      def self.company?(contact, params)
        case params["company"]
        when "1" then true
        when "0" then false
        else contact.company?
        end
      end

      # Whether the save is refused for want of a name, each kind
      # asking its own: a company its organization field, a person
      # either half of the pair (Admin::NamePair). The server's half
      # of the browser's `required`.
      #: (Contact contact, Hash[String, untyped] params) -> bool
      def self.nameless?(contact, params)
        if company?(contact, params)
          params["organization"].to_s.strip.empty?
        else
          params["first"].to_s.strip.empty? && params["last"].to_s.strip.empty?
        end
      end

      # The contact editor's save, spliced into the stored card. Where
      # each kind keeps its name, and the switch between the two, is
      # docs/plans/2026-10-07-switching-company-and-person.md.
      #: (Contact contact, String first, String middle, String last, Hash[String, untyped] params) -> VCard
      def self.contact_card(contact, first, middle, last, params)
        # The rows are read off the contact's own card, the one the form
        # rendered (Admin::ContactsEdit) and the one this save splices:
        # a line a group lends is on neither, so no digest here can name
        # one and no save can copy a group's value onto its member
        # (Contact#own).
        own = contact.own

        vcard = contact.stored
        vcard =
          if company?(contact, params)
            company_name(vcard, params["organization"].to_s.strip)
          else
            person_name(contact, vcard, first, middle, last, params["organization"]&.to_s&.strip)
          end
        vcard = edited_text(vcard, "NICKNAME", params["nickname"], own.nickname)
        vcard = edited_text(vcard, "NOTE", params["note"], note_of(own))
        vcard = edited_values(own.phones, "phone", "TEL", vcard, params)
        vcard = edited_values(own.emails, "email", "EMAIL", vcard, params)
        edited_addresses(own, vcard, params)
      end

      # The group editor's save: the note replaced and the contact
      # editor's own address splice over the group's lines read as a
      # card (Group#reading), then back into the lines a group
      # holds — each unfolded and shorn of its terminator, the unit
      # CardDiff records a write in and group_properties stores.
      #: (Group group, Hash[String, untyped] params) -> Array[String]
      def self.group_lines(group, params)
        reading = group.reading
        card = edited_text(reading.stored, "NOTE", params["note"], note_of(reading))
        card = edited_addresses(reading, card, params)
        card.lines.filter_map {
          line = it.content
          line unless line.empty?
        }
      end

      # The birthday row's parse: each blank component is an absence
      # and three blanks are no birthday, so Birthday's constructor is
      # the whole grammar — six shapes, ranges standing where the
      # components stand — and the digit check before it keeps to_i
      # honest (a "19x5" is not the year 19). All three blank returns
      # before the constructor, the grammar refusing nothing-at-all;
      # raises ArgumentError otherwise, the constructor's own refusal
      # class, for the save to catch and re-render — nothing here
      # reaches Sentry, bad input being ordinary and the toast the
      # fallback.
      #
      # A full date in 1604 is a month and day, the sentinel read here as
      # every client's line reads it (Birthday::NO_YEAR): the model would
      # otherwise hold a year that serves as a bare 1604 date and reads
      # back without one at the next sync
      # (docs/plans/2026-09-11-every-birthday-in-the-model.md, "1604 means
      # no year").
      #: (untyped fields) -> Birthday?
      def self.birthday(fields)
        year = birthday_component(fields["year"])
        month = birthday_component(fields["month"])
        day = birthday_component(fields["day"])
        return if year.nil? && month.nil? && day.nil?

        year = nil if year == Birthday::NO_YEAR && month && day

        Birthday.new(year:, month:, day:)
      end

      # The note the editor renders: every NOTE the member's own card
      # carries, joined the way composition joins them
      # (Contact#composed_note), so a card from before the one-note
      # invariant shows its second note rather than losing it to a save
      # that wrote only the first (docs/plans/2026-09-25-one-note-per-
      # contact.md). Nil for none, the row's blank-removes cue.
      #: (Contact contact) -> String?
      def self.note_of(contact)
        notes = contact.notes.map(&:value)
        notes.join("\n\n") unless notes.empty?
      end

      # A text property's half of the surgical save: the lines stay as
      # they are where the field submits what the form rendered from
      # them, and are replaced by #text_lines otherwise. Compared as
      # the field comes back — stripped, a textarea's line breaks CRLF
      # (the HTML form-submission newline normalization) — so a save
      # that left the field alone cannot re-escape, unfold, or strip
      # the parameters off a line it never changed.
      #: (VCard vcard, String name, untyped submitted, String? rendered) -> VCard
      def self.edited_text(vcard, name, submitted, rendered)
        value = submitted.to_s.gsub(/\r\n?/, "\n").strip
        return vcard if value == rendered.to_s.strip

        vcard.replace(name, text_lines(name, value))
      end

      # The single-value rows' half of the surgical save, walked once
      # for the phones and once for the emails: each row names its line
      # by digest, so a row the request leaves out is a line the save
      # never mentions, and an unchanged row is skipped — the line keeps
      # its own bytes by construction, not by careful re-rendering. A
      # blank row removes its line; a changed row swaps the value under
      # the line's own header (VCard.header_of), where the TYPE
      # parameters no field models ride. The rows come from the
      # contact, never the request, so a doctored digest names nothing
      # and a missing one touches nothing.
      #
      # `field` is the form's name for the kind and `name` the property
      # an added row is written as. The rows the add dialog reveals
      # (Admin::ContactsEdit) land as bare lines before END:VCARD, and a
      # blank one inserts nothing — inserting absence is a no-op, the
      # plan's rule for new rows, and the reason the rows nobody typed
      # in cost nothing whether they were on screen or not. Array()
      # because the field is a list and a request carrying one value
      # is still a list of one.
      #: (Array[Contact::Phone | Contact::Email] rows, String field, String name, VCard vcard, Hash[String, untyped] params) -> VCard
      def self.edited_values(rows, field, name, vcard, params)
        edits = params[field]
        if edits
          rows.each do |row|
            # These rows read from lines that did (Contact#phones), so
            # a nil is a broken assumption.
            property = row.line.property or raise "a #{field} row read from a line that will not read"

            submitted = edits[row.line.digest]
            next if submitted.nil? || submitted.to_s.strip == row.value.strip

            value = submitted.to_s.strip
            vcard = vcard.substitute(
              row.line.digest,
              value.empty? ? [] : ["#{VCard.header_of(property)}#{VCard.escape(value)}"],
            )
          end
        end

        submitted = Array(params["new_#{field}"]) #: Array[untyped]
        added = submitted.filter_map {
          value = it.to_s.strip
          "#{name}:#{VCard.escape(value)}" unless value.empty?
        } #: Array[String]
        vcard.insert(added)
      end

      # #edited_values' walk, over a row that is six fields rather than
      # one (Admin::ContactsEdit). Removal is the reader's own rule
      # (Contact#address_of): a row blank throughout, po box included,
      # removes the line, where a partially blanked one keeps it —
      # partial blanks are legal empty components. Every row is a hash,
      # the shape the form posts and Web#card_form_params holds a
      # request to.
      #: (Contact contact, VCard vcard, Hash[String, untyped] params) -> VCard
      def self.edited_addresses(contact, vcard, params)
        rows = params["address"]
        if rows
          contact.addresses.each do |address|
            submitted = rows[address.line.digest]
            next if submitted.nil? || address_unchanged?(address, submitted)

            line = address_line(address, submitted)
            vcard = vcard.substitute(address.line.digest, line ? [line] : [])
          end
        end

        # The add dialog names an added address by its add index
        # (`new_address[i][street]`) rather than the bare [] every
        # single-valued kind appends to, because Rack refuses a key
        # after an empty one — so the rows arrive as a hash of hashes
        # and read out by their values, several adds in one pass
        # included.
        added = params["new_address"] #: Hash[String, Hash[String, untyped]]?
        return vcard if added.nil?

        vcard.insert(added.values.filter_map { address_line(nil, it) })
      end

      #: (Contact::Address address, Hash[String, untyped] submitted) -> bool
      def self.address_unchanged?(address, submitted)
        Contact::ADDRESS_COMPONENTS.all? { |name|
          submitted[name].to_s.strip == address.public_send(name).to_s.strip
        }
      end

      # One address row's replacement line: the raw components spliced
      # and re-joined under the line's own header, or nil when the result
      # is blank throughout (blank is absent, the reader's own rule for
      # an ADR — the caller removes the line). A component that submits
      # its current reading keeps its own bytes — the po box always,
      # having no field, and any other the form left alone — where a
      # moved one re-escapes from the form; the splice over
      # still-escaped components is n_line's own rule,
      # unescape-then-re-escape not being byte-stable. A nil address is
      # an added row: seven fresh positions, po box empty, a bare ADR
      # header.
      #: (Contact::Address? address, Hash[String, untyped] submitted) -> String?
      def self.address_line(address, submitted)
        property = address && address.line.property
        if property.nil?
          components = [""]
        else
          components = VCard.split_raw_components(property.value)
        end
        components << "" while components.length < 7
        Contact::ADDRESS_COMPONENTS.each_with_index do |name, index|
          position = index + 1
          value = submitted[name].to_s.strip
          current = address && address.public_send(name).to_s.strip
          components[position] = value == current ? components.fetch(position) : VCard.escape(value)
        end
        return if components.all?(&:empty?)

        header = property ? VCard.header_of(property) : "ADR:"
        "#{header}#{components.join(";")}"
      end

      # One component off the wire: nil for blank, the integer it names
      # otherwise. Digits only — a month select and ranged number inputs
      # are the browser's own constraint, and this is the server's.
      #: (untyped submitted) -> Integer?
      def self.birthday_component(submitted)
        value = submitted.to_s.strip
        return nil if value.empty?
        raise ArgumentError, "not a number a birthday holds: #{value.inspect}" unless value.match?(/\A\d{1,4}\z/)

        value.to_i
      end

      # A text property's replacement lines: the escaped value (RFC 2426
      # section 2.4.2 — the value is text, the line is structure), or none
      # at all — blank equals absent, the whole-property rule.
      #: (String name, String value) -> Array[String]
      def self.text_lines(name, value)
        return [] if value.empty?

        ["#{name}:#{VCard.escape(value)}"]
      end

      # A company's name, written where macOS writes one (exchange
      # ec5ce1d8dd03 in log/dev.log, 2026-10-07): ORG's first component
      # and FN both, under X-ABShowAs:COMPANY, with N empty. A company
      # has no person's name, and one left in N would be a name no
      # screen here shows (the editor hides the pair for a company), so
      # a person made a company leaves theirs behind, prefixes and
      # suffixes too, and a switch back is typed afresh, as Contacts.app
      # asked for it. Each line is rewritten only where it says
      # something else, so an untouched save of the card macOS wrote
      # keeps its bytes.
      #: (VCard vcard, String organization) -> VCard
      def self.company_name(vcard, organization)
        vcard = vcard.replace("N", ["N:;;;;"]) unless vcard.property("N")&.components&.all?(&:empty?)
        vcard = vcard.replace("FN", ["FN:#{VCard.escape(organization)}"]) unless vcard.property("FN")&.text == organization
        vcard = edited_organization(vcard, organization)
        return vcard if vcard.property("X-ABShowAs")&.text == "COMPANY"

        vcard.replace("X-ABShowAs", ["X-ABShowAs:COMPANY"])
      end

      # A person's name, into N and FN, and the flag gone: a person is
      # a card without X-ABShowAs, which is how macOS unticks Company
      # (exchange b5ce7eaebe0e). ORG is the person's employer, written
      # from the same field as a company's name; a POST without that
      # field leaves it be, the birthday group's posture.
      #: (Contact contact, VCard vcard, String first, String middle, String last, String? organization) -> VCard
      def self.person_name(contact, vcard, first, middle, last, organization)
        line = n_line(vcard, first, middle, last)
        vcard = vcard.replace("N", [line]) if line
        vcard = edited_fn(contact, vcard, first, middle, last)
        vcard = edited_organization(vcard, organization) if organization
        vcard.replace("X-ABShowAs", [])
      end

      # An organization's own name: ORG's first component (RFC 2426
      # section 3.5.5), the units after it being no part of it. Public
      # for the editor's prefill (Admin::ContactsEdit), which reads the
      # name this save writes.
      #: (VCard vcard) -> String?
      def self.organization_of(vcard)
        vcard.property("ORG")&.components&.first
      end

      # ORG with the organization field's name in it, or the card
      # untouched where the name already is that. The name is the first
      # component, the units after it rejoined byte for byte — n_line's
      # splice, for n_line's reason. Blank removes the property, the
      # whole-property rule, units and all: they are no row of their own
      # here, and a department of no organization is not one to keep.
      #: (VCard vcard, String organization) -> VCard
      def self.edited_organization(vcard, organization)
        return vcard if organization_of(vcard).to_s == organization
        return vcard.replace("ORG", []) if organization.empty?

        property = vcard.property("ORG")
        units = [] #: Array[String]
        units = VCard.split_raw_components(property.value).drop(1) if property
        vcard.replace("ORG", ["ORG:#{[VCard.escape(organization), *units].join(";")}"])
      end

      # FN's replacement, or the card untouched: the display name is the
      # card's own text (RFC 2426 section 3.1.1), not a rendering of N,
      # and "Dr. Ada B. Lovelace, Jr." holds parts no field on this form
      # does — the same parts n_line rejoins byte for byte rather than
      # dropping. Rebuilding it under a save that only moved a phone
      # number would lose them, so FN is rewritten only when a name
      # field moved under it, which is the one time the old display
      # name is stale. A card carrying no FN is the other case: the
      # property is mandatory (section 4), so a save fills it in rather
      # than leaving the absence it found.
      #: (Contact contact, VCard vcard, String first, String middle, String last) -> VCard
      def self.edited_fn(contact, vcard, first, middle, last)
        family, given, additional = contact.name_components || []
        named = !vcard.property("FN").nil?
        # A company's FN is its organization's name (#company_name), so
        # a card leaving that kind takes its display name from the pair.
        unchanged = first == given.to_s.strip && middle == additional.to_s.strip && last == family.to_s.strip
        return vcard if named && !contact.company? && unchanged

        vcard.replace("FN", ["FN:#{VCard.escape(display_name(first, middle, last))}"])
      end

      # FN's text, from the boxes that make it: the western order the
      # fixture sessions show macOS writing, each blank box left out
      # rather than spacing the line.
      #: (String first, String middle, String last) -> String
      def self.display_name(first, middle, last)
        [first, middle, last].reject(&:empty?).join(" ")
      end

      # N's replacement line. The first three components are the form's
      # — family, given, additional (RFC 2426 section 3.1.2) — and the
      # prefixes and suffixes after them rejoin byte for byte, which is
      # what the splice over the still-escaped value buys
      # (docs/plans/2026-09-05-web-card-editor.md). A component that
      # submits its current reading keeps its own bytes too, the rule
      # address_line already writes under: unescape-then-re-escape is
      # not byte-stable (VCard.split_raw_components), so a save that
      # moved a phone number must not rewrite the name it left alone. A
      # card with no N a form can read splices into a bare
      # five-component value; one short of five is padded, the same
      # empties a whole-N writer would leave. Nil where every name box
      # submits what it rendered, so the line keeps what no box models
      # — its parameters, its group, its folds — and is not rewritten.
      # A box's value arrives stripped, and is compared with the reading
      # stripped likewise.
      #: (VCard vcard, String first, String middle, String last) -> String?
      def self.n_line(vcard, first, middle, last)
        property = vcard.property("N")
        components = [] #: Array[String]
        readings = [] #: Array[String]
        if property
          components.replace(VCard.split_raw_components(property.value))
          readings.replace(property.components)
        end
        currents = Array.new(3) { readings[it].to_s.strip }
        return if property && [last, first, middle] == currents

        components << "" while components.length < 5
        [last, first, middle].each_with_index do |value, position|
          components[position] = value == currents.fetch(position) ? components.fetch(position) : VCard.escape(value)
        end
        "N:#{components.join(";")}"
      end

      private_class_method :edited_values, :edited_addresses, :address_unchanged?,
                           :address_line, :birthday_component, :text_lines, :edited_text, :edited_fn, :display_name,
                           :n_line, :company_name, :person_name, :edited_organization
    end
  end
end
