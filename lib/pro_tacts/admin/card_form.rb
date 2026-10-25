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
      # The repeatable rows by the form's name for each kind: the field
      # a standing row posts under and, prefixed `new_`, the one an
      # added row does, each reading back into the row class that
      # writes it (#edited_rows). Public for the route's shape checks
      # (Web#card_form_params) and the editor's rows. The address is
      # not among them: it is a component rather than a card line, and
      # its rows save through #addresses.
      ROWS = {
        "phone" => Contact::Phone,
        "email" => Contact::Email,
        "handle" => Contact::Handle,
      }.freeze #: Hash[String, Contact::row_class]

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

      # Whether the save is refused for want of a name, each kind
      # asking its own: a company its organization field, a person
      # either half of the pair (Admin::NamePair). The server's half
      # of the browser's `required`. `company` is the editor's Company
      # box, which posts "1" checked and the hidden "0" before it
      # otherwise, so every save names the kind it writes.
      #: (bool company, Hash[String, untyped] params) -> bool
      def self.nameless?(company, params)
        if company
          params["organization"].to_s.strip.empty?
        else
          params["first"].to_s.strip.empty? && params["last"].to_s.strip.empty?
        end
      end

      # The contact editor's save, spliced into the stored card. Where
      # each kind keeps its name, and the switch between the two, is
      # docs/plans/2026-10-07-switching-company-and-person.md. The
      # addresses and the note are the entity's components, not card
      # lines: they save through #addresses and #note, which the route
      # hands to Store#save_edit beside the card this returns.
      #: (Contact contact, bool company, String first, String middle, String last, Hash[String, untyped] params) -> VCard
      def self.contact_card(contact, company, first, middle, last, params)
        # The rows are read off the contact's own card, the one the form
        # rendered (Admin::ContactsEdit) and the one this save splices:
        # a line a group lends is on neither, so no digest here can name
        # one and no save can copy a group's value onto its member
        # (Contact#own).
        own = contact.own

        vcard = contact.stored
        vcard =
          if company
            company_name(vcard, params["organization"].to_s.strip)
          else
            person_name(contact, vcard, first, middle, last, params["organization"]&.strip)
          end
        vcard = edited_text(vcard, "NICKNAME", params["nickname"], own.nickname)
        vcard = edited_rows(own.phones, "phone", vcard, params)
        vcard = edited_rows(own.emails, "email", vcard, params)
        edited_rows(own.handles, "handle", vcard, params)
      end

      # The address rows the editor posts, as the entity's whole new
      # address list: the standing rows by their position — a blank one
      # removed, a missing one kept, any other rewritten, and the po
      # box preserved, no field editing it — then the added ones
      # (Admin::ContactsEdit#added_rows), in submission order
      # (docs/plans/2026-10-25-contacts-on-entities.md, "Matching what
      # comes back", which gives a PUT's unclaimed addresses the same
      # rule). `rows` are the contact's own or the group's, the two
      # editors' rows alike; a group's address carries a label like a
      # card's (that plan, "A group's address carries a label like a
      # card's").
      #: (Array[Contact::Address] rows, Hash[String, untyped] params) -> Array[Contact::Address]
      def self.addresses(rows, params)
        edits = hash_field(params, "address").sort_by { |key, _| key.to_i }.map { |_, fields| fields }
        standing = rows.zip(edits).filter_map { |row, submitted|
          next row if submitted.nil?

          address_of(submitted, row)
        }
        added = hash_field(params, "new_address").values.filter_map { |fields| address_of(fields) }
        [*standing, *added]
      end

      # One address row's fields, as the editor posts them, read back
      # into the component: the six components by name, the label
      # beside them — a blank label is no label, an absent one the row's
      # own, for a form that renders no label field — and the po box
      # preserved from the row it replaces, no field editing it.
      # Fields that arrive blank read as absent, and a row blank
      # throughout, po box included, is no address at all, the
      # blank-equals-absent rule; `over` is nil for an added row,
      # whose po box is empty.
      #: (Hash[String, untyped] fields, ?Contact::Address? over) -> Contact::Address?
      def self.address_of(fields, over = nil)
        components = Contact::ADDRESS_COMPONENTS.to_h { |name|
          pair = [name, fields[name].to_s.strip] #: [String, String]
          pair
        }
        label = fields.key?("label") ? fields["label"].to_s.strip : over&.label.to_s
        blank = over&.po_box.to_s.empty? && components.values.all?(&:empty?)
        return if blank

        Contact::Address.new(
          po_box: over&.po_box.to_s,
          extended: components.fetch("extended"),
          street: components.fetch("street"),
          locality: components.fetch("locality"),
          region: components.fetch("region"),
          postal_code: components.fetch("postal_code"),
          country: components.fetch("country"),
          label: label.empty? ? nil : label
        )
      end

      # The group editor's save: the group's whole new components,
      # the same rows the contact editor posts (#addresses, #note).
      #: (Group group, Hash[String, untyped] params) -> [Array[Contact::Address], String?]
      def self.group_components(group, params)
        [addresses(group.addresses, params), note(params["note"], group.note)]
      end

      # Components composed back into a card as lines, for the one
      # write path a create has — Store#put, which takes them back off
      # it through the same reading the form's rows came from
      # (Contact.take_addresses, Contact.take_note). The import's Save
      # over a staged card, which has no entity yet to write components
      # against.
      #: (VCard card, Array[Contact::Address] addresses, String? note) -> VCard
      def self.composed_card(card, addresses, note)
        addresses.each { card = card.insert(Contact.address_lines(card, it)) }
        note ? card.insert(["NOTE:#{VCard.escape(note)}"]) : card
      end

      # The note field's save: the submitted text with a textarea's
      # line breaks normalized, or nil where it reads blank — blank is
      # absent, the whole-property rule. The comparison against what
      # the form rendered is the editor's own; nothing byte-level
      # stands behind a note, which is a component.
      #: (untyped submitted, String? rendered) -> String?
      def self.note(submitted, rendered)
        value = submitted.to_s.gsub(/\r\n?/, "\n").strip
        value.empty? ? nil : value
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

      # The note the editor renders: the member's own, the component
      # the entity holds (Contact#own#note). Nil for none, the row's
      # blank-removes cue.
      #: (Contact contact) -> String?
      def self.note_of(contact)
        contact.own.note
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

      # The repeatable rows' half of the surgical save, walked once per
      # kind: each row names its line by digest, so a row the request
      # leaves out is a line the save never mentions, and a row whose
      # label and fields all submit what it read is skipped — the line
      # keeps its own bytes by construction, not by careful
      # re-rendering. Any other is the row's to rewrite (Contact::Phone#edit
      # and kin), which is where the kinds differ: what a blank removes
      # and where a label is written
      # (docs/plans/2026-10-22-a-row-edits-its-label.md). A row posting
      # no label leaves its label be, as the group editor's addresses
      # do. The rows come from the contact, never the request, so a
      # doctored digest names nothing and a missing one touches nothing.
      #
      # `field` is the form's name for the kind. The rows the add
      # dialog reveals (Admin::ContactsEdit) are named by their add
      # index (`new_phone[i][value]`) rather than a bare [], because
      # Rack refuses a key after an empty one — so they arrive as a
      # hash of hashes and read out by their values, landing as bare
      # lines before END:VCARD. A blank one inserts nothing.
      #: (Array[Contact::Phone | Contact::Email | Contact::Handle] rows, String field, VCard vcard, Hash[String, untyped] params) -> VCard
      def self.edited_rows(rows, field, vcard, params)
        kind = ROWS.fetch(field)
        edits = hash_field(params, field)
        rows.each do |row|
          submitted = edits[row.line.digest]
          next if submitted.nil?

          label = submitted["label"]&.strip
          fields = submitted_fields(kind, submitted)
          next if (label.nil? || label == row.label.to_s.strip) && fields.all? { |name, value| value == row.fields.fetch(name).strip }

          vcard = row.edit(vcard, label, fields)
        end

        added = hash_field(params, "new_#{field}").values #: Array[Hash[String, untyped]]
        added.each do |row|
          vcard = kind.add(vcard, row["label"].to_s.strip, submitted_fields(kind, row))
        end
        vcard
      end

      #: (Contact::row_class kind, Hash[String, untyped] submitted) -> Hash[String, String]
      def self.submitted_fields(kind, submitted)
        kind.field_names.to_h {
          field = [it, submitted[it].to_s.strip] #: [String, String]
          field
        }
      end

      # A field the editors post as a hash keyed by row: none where the
      # form rendered no such rows, and a raise for any other shape.
      # Web#card_form_params answers that shape as a 400 before a save
      # gets here, so the raise is the assertion that it did.
      #: (Hash[String, untyped] params, String key) -> Hash[String, untyped]
      def self.hash_field(params, key)
        none = {} #: Hash[String, untyped]
        value = params.fetch(key, none)
        raise ArgumentError, "the form's #{key} field is not a hash" unless value.is_a?(Hash)

        value
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
      # Contact.address_value already writes under: unescape-then-re-escape is
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

      private_class_method :edited_rows, :submitted_fields, :hash_field, :birthday_component, :text_lines, :edited_text, :edited_fn, :display_name,
                           :n_line, :company_name, :person_name, :edited_organization, :address_of
    end
  end
end
