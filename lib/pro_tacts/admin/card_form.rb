require "pro_tacts/birthday"
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
      # ADR's editable components: field name to position in the value
      # (RFC 2426 section 3.2.1, minus the leading po box at position 0
      # — no screen shows one, and the save preserves its bytes rather
      # than letting a form field near them). In the value's own order,
      # which is the order a rebuilt line's components join in.
      ADDRESS_COMPONENTS = {
        "extended" => 1,
        "street" => 2,
        "locality" => 3,
        "region" => 4,
        "postal_code" => 5,
        "country" => 6,
      }.freeze #: Hash[String, Integer]
      private_constant :ADDRESS_COMPONENTS

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

      # The contact editor's save, spliced into the stored card.
      #: (Contact contact, String first, String middle, String last, Hash[String, untyped] params) -> VCard
      def self.contact_card(contact, first, middle, last, params)
        nickname = params["nickname"].to_s.strip
        note = params["note"].to_s.strip

        # The rows are read off the contact's own card, the one the form
        # rendered (Admin::ContactsEdit) and the one this save splices:
        # a line a group lends is on neither, so no digest here can name
        # one and no save can copy a group's value onto its member
        # (Contact#own).
        own = contact.own

        vcard = contact.stored
        vcard = vcard.replace("N", [n_line(vcard, first, middle, last)])
        vcard = edited_fn(contact, vcard, first, middle, last)
        vcard = vcard.replace("NICKNAME", text_lines("NICKNAME", nickname))
        vcard = vcard.replace("NOTE", text_lines("NOTE", note))
        vcard = edited_phones(own, vcard, params)
        vcard = edited_emails(own, vcard, params)
        edited_addresses(own, vcard, params)
      end

      # The group editor's save: the note replaced and the contact
      # editor's own address splice over the group's lines read as a
      # card (Store::Group#reading), then back into the lines a group
      # holds — each unfolded and shorn of its terminator, the unit
      # CardDiff records a write in and group_properties stores.
      #: (Store::Group group, Hash[String, untyped] params) -> Array[String]
      def self.group_lines(group, params)
        reading = group.reading
        card = reading.stored.replace("NOTE", text_lines("NOTE", params["note"].to_s.strip))
        card = edited_addresses(reading, card, params)
        card.lines.filter_map {
          line = VCard::Parser.unfold(it.verbatim).sub(/(\r\n|[\r\n])\z/, "")
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
      #: (untyped fields) -> Birthday?
      def self.birthday(fields)
        year = birthday_component(fields["year"])
        month = birthday_component(fields["month"])
        day = birthday_component(fields["day"])
        return if year.nil? && month.nil? && day.nil?

        Birthday.new(year:, month:, day:)
      end

      # The phones' half of the surgical save: each row names its line
      # by digest, so a row the request leaves out is a line the save
      # never mentions, and an unchanged row is skipped — the line keeps
      # its own bytes by construction, not by careful re-rendering. A
      # blank row removes its line; a changed row swaps the value under
      # the line's own header (VCard.header_of), where the TYPE
      # parameters no field models ride. The addresses come from the
      # contact, never the request, so a doctored digest names nothing
      # and a missing one touches nothing.
      #: (Contact contact, VCard vcard, Hash[String, untyped] params) -> VCard
      def self.edited_phones(contact, vcard, params)
        rows = params["phone"]
        if rows.is_a?(Hash)
          contact.phones.each do |phone|
            # The property is nil only for a line that would not read,
            # and phones read from lines that did; the guard is the
            # type's honesty, not a reachable case (n_line's own shape).
            property = phone.line.property
            next if property.nil?

            submitted = rows[phone.line.digest]
            next if submitted.nil? || submitted.to_s.strip == phone.value

            value = submitted.to_s.strip
            vcard = vcard.substitute(
              phone.line.digest,
              value.empty? ? [] : ["#{VCard.header_of(property)}#{VCard.escape(value)}"]
            )
          end
        end

        # The rows the add dialog reveals (Admin::ContactsEdit): each
        # value lands as a bare TEL before END:VCARD, and a blank one
        # inserts nothing — inserting absence is a no-op, the plan's
        # rule for new rows, and the reason the rows nobody typed in
        # cost nothing whether they were on screen or not. Array()
        # because the field is a list and a request carrying one value
        # is still a list of one.
        submitted = Array(params["new_phone"]) #: Array[untyped]
        added = submitted.filter_map {
          value = it.to_s.strip
          "TEL:#{VCard.escape(value)}\r\n" unless value.empty?
        } #: Array[String]
        vcard.insert(added)
      end

      # #edited_phones' walk, over EMAIL.
      #: (Contact contact, VCard vcard, Hash[String, untyped] params) -> VCard
      def self.edited_emails(contact, vcard, params)
        rows = params["email"]
        if rows.is_a?(Hash)
          contact.emails.each do |email|
            property = email.line.property
            next if property.nil?

            submitted = rows[email.line.digest]
            next if submitted.nil? || submitted.to_s.strip == email.value

            value = submitted.to_s.strip
            vcard = vcard.substitute(
              email.line.digest,
              value.empty? ? [] : ["#{VCard.header_of(property)}#{VCard.escape(value)}"],
            )
          end
        end

        submitted = Array(params["new_email"]) #: Array[untyped]
        added = submitted.filter_map {
          value = it.to_s.strip
          "EMAIL:#{VCard.escape(value)}\r\n" unless value.empty?
        } #: Array[String]
        vcard.insert(added)
      end

      # #edited_phones' walk, over a row that is six fields rather than
      # one (Admin::ContactsEdit). Removal is the reader's own rule
      # (Contact#address_of): a row blank throughout, po box included,
      # removes the line, where a partially blanked one keeps it —
      # partial blanks are legal empty components.
      #: (Contact contact, VCard vcard, Hash[String, untyped] params) -> VCard
      def self.edited_addresses(contact, vcard, params)
        rows = params["address"]
        if rows.is_a?(Hash)
          contact.addresses.each do |address|
            property = address.line.property
            next if property.nil?

            submitted = rows[address.line.digest]
            next if !submitted.is_a?(Hash) || address_unchanged?(address, submitted)

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
        submitted = params["new_address"]
        added = submitted.is_a?(Hash) ? submitted.values : Array(submitted) #: Array[untyped]
        vcard.insert(added.filter_map { address_line(nil, it) })
      end

      #: (Contact::Address address, untyped submitted) -> bool
      def self.address_unchanged?(address, submitted)
        ADDRESS_COMPONENTS.keys.all? { |name|
          submitted[name].to_s.strip == address.public_send(name).to_s
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
      #: (Contact::Address? address, untyped submitted) -> String?
      def self.address_line(address, submitted)
        return unless submitted.is_a?(Hash)

        property = address && address.line.property
        if property.nil?
          components = [""]
        else
          components = VCard.split_raw_components(property.value)
        end
        components << "" while components.length < 7
        ADDRESS_COMPONENTS.each do |name, position|
          value = submitted[name].to_s.strip
          current = address && address.public_send(name).to_s
          components[position] = value == current ? components.fetch(position) : VCard.escape(value)
        end
        return if components.all?(&:empty?)

        header = property ? VCard.header_of(property) : "ADR:"
        "#{header}#{components.join(";")}\r\n"
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

        ["#{name}:#{VCard.escape(value)}\r\n"]
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
        named = vcard.properties.any? { it.name.casecmp?("FN") }
        return vcard if named && first == given.to_s && middle == additional.to_s && last == family.to_s

        vcard.replace("FN", ["FN:#{VCard.escape(display_name(first, middle, last))}\r\n"])
      end

      # FN's text, from the boxes that make it: the western order the
      # create dialog has always written (Admin::ContactDialog), each
      # blank box left out rather than spacing the line.
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
      # empties a whole-N writer would leave.
      #: (VCard vcard, String first, String middle, String last) -> String
      def self.n_line(vcard, first, middle, last)
        property = vcard.properties.find { it.name.casecmp?("N") }
        components = [] #: Array[String]
        readings = [] #: Array[String]
        if property
          components.replace(VCard.split_raw_components(property.value))
          readings.replace(property.components)
        end
        components << "" while components.length < 5
        # The form's three, in the value's own order: family, given,
        # additional.
        [last, first, middle].each_with_index do |value, position|
          current = readings[position].to_s
          components[position] = value == current ? components.fetch(position) : VCard.escape(value)
        end
        "N:#{components.join(";")}\r\n"
      end

      private_class_method :edited_phones, :edited_emails, :edited_addresses, :address_unchanged?,
                           :address_line, :birthday_component, :text_lines, :edited_fn, :display_name,
                           :n_line
    end
  end
end
