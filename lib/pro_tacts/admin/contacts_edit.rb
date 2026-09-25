require "date"

require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/icons"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/name_pair"
require "pro_tacts/admin/record_card"

module ProTacts
  module Admin
    # GET /contacts/:id/edit — the editor. What the save can address,
    # how each kind of row is written back, and the
    # blank-equals-absent rule are
    # docs/plans/2026-09-05-web-card-editor.md and
    # docs/plans/2026-09-07-web-birthday-editor.md; the fields
    # prefill from the accessors' unescaped readings so write and read
    # agree on what an empty value means.
    #
    # What is this screen's own is telling the person that rule before
    # the save enforces it. A standing row whose blanking deletes
    # wears `data-blank-removes`, its single-value box says "removed
    # on save" in its blank, and admin.css strikes the caption in
    # Gloss's danger color once every value in the row reads blank.
    # The caption carries the color rather than the boxes' borders,
    # because a blank row is a valid save and Gloss's danger border is
    # the aria-invalid contract. The state is CSS over
    # :placeholder-shown rather than Alpine — revealing a state over
    # standing elements is markup's job (see Layout).
    #
    # Two kinds of row wear none of it: the ones the add dialog
    # reveals, whose blank is a no-op rather than a removal, and a
    # nickname or note row over a card that carries neither, which has
    # nothing to lose. The etag rides along hidden, the snapshot
    # guard's half. `autofocus` on the first field: this screen's
    # entry point is the name, not the header search.
    class ContactsEdit < Phlex::HTML
      # The property types the add dialog offers, in the order it
      # lists them — exactly the rows the save can insert
      # (docs/plans/2026-09-05-web-card-editor.md), because a type
      # listed here that the save cannot write would be a row that
      # silently does nothing. Each name is the radio's value;
      # `new_<type>[]` is the single-value kinds' field name and
      # `new_address[<i>][<component>]` the structured one's, the
      # bare [] unable to carry a component set (Rack refuses a key
      # after an empty one). The birthday is the exception: its
      # added row names the model's own `birthday[]` group, there
      # being no card line to insert and room for but one — see
      # #addable_types for when the dialog offers it.
      ADDABLE_TYPES = %w[phone email address birthday].freeze #: Array[String]
      private_constant :ADDABLE_TYPES

      # The form's id, for the footer's Save outside it.
      FORM = "contact-form" #: String
      private_constant :FORM

      # The address row's component fields, stacked in the value
      # column in the order an address form reads, which is not the
      # order the value spells them in (Contact::ADDRESS_COMPONENTS).
      # Field name to placeholder: a component is not an attribute and
      # earns no type column of its own, so the placeholder is the
      # label and the conventional order carries it. Public because a
      # group's address rows are these same rows (Admin::GroupsEdit).
      ADDRESS_FIELDS = [
        ["street", "street"],
        ["extended", "street 2"],
        ["locality", "city"],
        ["region", "region"],
        ["postal_code", "postal code"],
        ["country", "country"],
      ].freeze #: Array[[String, String]]

      # @rbs @contact: Contact
      # @rbs @login: String
      # @rbs @own: Contact
      # @rbs @sidebar: Phlex::HTML?
      # @rbs @save: String
      # @rbs @notice: String?
      # @rbs @first: String?
      # @rbs @middle: String?
      # @rbs @last: String?
      # @rbs @action: String
      # @rbs @back: ([String, String])?
      # @rbs @aside: Phlex::HTML?
      # @rbs @fields: Phlex::HTML?
      # @rbs @lead: Phlex::HTML?

      # The last seven are the import's: the same editor, over a card
      # that is not stored yet, saving into the import rather than
      # into a contact, rendered beside the card as it was exported
      # (Admin::ImportOriginal) and carrying what the walk decides
      # about a contact that a card cannot hold — which groups it
      # joins (Admin::ImportGroups), inside this form so that one Save
      # writes the lot, and `lead` what it writes into — a new contact
      # or one the book already has (Admin::ImportTarget), above the
      # fields it decides. `sidebar` is the walk's own list of contacts,
      # standing beside the pair (Admin::ImportSidebar), and `save`
      # the submit's words, which on an import say where the card is
      # going because it is not there yet. One editor rather than a
      # second one for imports, because a field the two disagreed
      # about is a field an import writes and an edit cannot undo.
      # Defaulted to the contact's own, so the ordinary edit says
      # nothing about any of it.
      #: (contact: Contact, login: String, ?notice: String?, ?action: String?, ?back: [String, String]?, ?aside: Phlex::HTML?, ?fields: Phlex::HTML?, ?lead: Phlex::HTML?, ?sidebar: Phlex::HTML?, ?save: String?) -> void
      def initialize(contact:, login:, notice: nil, action: nil, back: nil, aside: nil, fields: nil,
                     lead: nil, sidebar: nil, save: nil)
        @contact = contact
        @login = login
        @action = action || "/contacts/#{contact.id}"
        @back = back
        @aside = aside
        @fields = fields
        @lead = lead
        @sidebar = sidebar
        @save = save || "Save"
        # The rows are the contact's own, never what a group lends it
        # (Contact#own); the details page is where an inherited row is
        # read (Admin::ContactsShow). The etag below is still the
        # composed contact's, the one a save is guarded against.
        @own = contact.own
        @notice = notice
        # N's first three components (RFC 2426 section 3.1.2: family;
        # given; additional) — the three fields the create dialog also
        # asks for. The prefixes and suffixes after them are preserved
        # byte-for-byte by the save's raw splice (CardForm.n_line),
        # never rendered here.
        family, given, additional = contact.name_components || []
        @first = given
        @middle = additional
        @last = family
      end

      def view_template
        # Wide only when something is beside the editor: the reading
        # width a single column wants is still what one card gets
        # (admin.css).
        render Layout.new(title: "Edit #{@contact.name || @contact.id}", login: @login,
                          wide: !@aside.nil? || !@sidebar.nil?, notice: @notice) do
          # The editor's Alpine scope, wrapping the record and the add
          # dialog both: the dialog names a type and the form grows a
          # row for it, so the two have to share state, and Alpine
          # scopes by ancestry. `added` is the list of types added
          # this pass, `type` is the radio's binding, and the rest is
          # the name boxes' (NamePair).
          div(x_data: "{ added: [], type: '#{ADDABLE_TYPES.first}', #{NamePair.state(@first, @last)} }") do
            render RecordCard.new(
              back: @back,
              nav: -> {
                button(type: "button", data_size: "sm",
                       popovertarget: "add-property") { "add property" }
              },
              aside: @aside,
              sidebar: @sidebar,
              submit: @save,
              form: FORM,
            ) do
                form(action: @action, method: "post", class: "field-stack", id: FORM) do
                  input(type: "hidden", name: "etag", value: @contact.etag)
                  # First, and only where something passed it: what the
                  # save writes into decides every field below it.
                  render @lead if @lead
                  # The caption is an element rather than bare text
                  # because the row is a grid (admin.css): a text node
                  # would still land in the type column as an
                  # anonymous grid item, but nothing could then reach
                  # it, and the note's caption needs reaching.
                  # The name, as an organization spells it or a person:
                  # one field for a company card (X-ABShowAs:COMPANY,
                  # Contact#company?), the pair and the middle box for
                  # everyone else. The organization field's wire name
                  # is `last` because that is where the name lives —
                  # N's family slot, the component the save splices
                  # (CardForm.n_line) — and the label says what the
                  # visitor knows it by. An unchecked company card
                  # submits no first or middle, and the save reads
                  # their absence as the empties they are.
                  if @contact.company?
                    label(class: "field") do
                      span { "Organization" }
                      input(type: "text", name: "last", value: @last, required: true, autofocus: true)
                    end
                  else
                    label(class: "field") do
                      span { "First" }
                      input(**NamePair.first(@first, @last), autofocus: true)
                    end
                    # Outside the required pair, and outside its removal
                    # state with it: a blanked middle name rewrites N's
                    # additional component like any other name box, and
                    # the row it would strike through is the name row,
                    # which no save can remove.
                    label(class: "field") do
                      span { "Middle" }
                      input(type: "text", name: "middle", value: @middle)
                    end
                    label(class: "field") do
                      span { "Last" }
                      input(**NamePair.last(@first, @last))
                    end
                  end
                  # The whole-property rows wear the removal state only
                  # over a property the card carries: both render empty
                  # when it does not, and a box that started blank
                  # cannot lose anything — "removed on save" in it
                  # would be a false alarm.
                  # Off the contact's own card like every row below, so
                  # no row here depends on which properties a group may
                  # lend (docs/plans/2026-09-09-group-edits-propagate.md,
                  # "Where the editor stands").
                  label(class: "field", data: {blank_removes: !!@own.nickname}) do
                    span { "Nickname" }
                    input(type: "text", name: "nickname", value: @own.nickname,
                          placeholder: @own.nickname ? "removed on save" : nil)
                  end
                  @own.phones.each do |phone|
                    value_row(Format.type_label(phone.label, phone.types, "phone"),
                              type: "tel", name: "phone[#{phone.line.digest}]", value: phone.value)
                  end
                  @own.emails.each do |email|
                    value_row(Format.type_label(nil, email.types, "email"),
                              type: "email", name: "email[#{email.line.digest}]", value: email.value)
                  end
                  @own.addresses.each do
                    address_row(it)
                  end
                  birthday_row
                  added_rows
                  # The first NOTE the card carries: this row edits one,
                  # and a save writes one (CardForm.contact_card's
                  # replace).
                  note = @own.notes.first&.value
                  label(class: "field", data: {blank_removes: !!note}) do
                    span { "Note" }
                    textarea(name: "note", rows: 4,
                             placeholder: note ? "removed on save" : nil) { note.to_s }
                  end
                  # Last, and only where something passed them: what
                  # is not a property of the card reads after
                  # everything that is.
                  render @fields if @fields
                end
              end
            add_property_dialog
          end
        end
      end

      private

      # The rows added this pass, rendered by Alpine from `added` —
      # one per type named in the dialog, in the order they were
      # asked for. Nothing stands here until something is added and
      # nothing lingers after: an empty row waiting to be used is the
      # scaffold docs/DESIGN.md refuses ("Records are cards, not
      # forms"). That verb — make a row, now, without a round trip —
      # is what CSS could not do and what Alpine is here for (see
      # Layout).
      #
      # The row is a div rather than the standing rows' label because
      # one template serves every kind and the address kind holds six
      # controls a label cannot name — so the single-value input
      # carries its own aria-label, and the address inputs their
      # placeholders.
      #
      # `x-init` on the input rather than autofocus: it runs when the
      # element is created, which is exactly when the row is added,
      # and there is nothing to focus on page load because `added`
      # starts empty.
      def added_rows
        template(x_for: "(kind, i) in added", ":key": "i") do
          div(class: "field") do
            span("x-text": "kind")
            # The single-value kinds: one input, its type and name
            # bound to the kind — the keyboard a phone number or an
            # email address wants, on the one client that has one.
            template("x-if": "kind !== 'address' && kind !== 'birthday'") do
              input(":type": "kind === 'phone' ? 'tel' : kind", ":name": "`new_${kind}[]`",
                    ":aria-label": "kind", "x-init": "$el.focus()")
            end
            # The address kind: the same six component fields a
            # standing row gets, named by the add index rather than a
            # digest — there is no line yet to digest, and the
            # []-appended name the other kinds use cannot carry a
            # component set (Rack refuses a key after a bare []).
            template("x-if": "kind === 'address'") do
              div(class: "field-stack") do
                ADDRESS_FIELDS.each_with_index do |(component, label), index|
                  input(type: "text", ":name": "`new_address[${i}][#{component}]`",
                        placeholder: label, aria_label: label,
                        "x-init": index.zero? ? "$el.focus()" : nil)
                end
              end
            end
            # The birthday kind: the standing row's own three
            # controls with nothing prefilled, naming the model's
            # birthday[] group rather than a new_* name — no card
            # line exists to insert, the save parses the group into
            # the model, and no digest is needed when a contact can
            # hold but one. No removal state, the added rows'
            # exemption: three blanks over a contact with no
            # birthday is nothing, not a removal. A second one
            # cannot arrive — the dialog stops offering the type
            # once this row stands, and Add's handler guards the
            # push anyway.
            template("x-if": "kind === 'birthday'") do
              div(class: "date-row") do
                birthday_controls(nil, focus: true)
              end
            end
          end
        end
      end

      # A standing single-value row — a phone, an email — editing its
      # value and nothing else: the TYPE parameters ride in the line's
      # own header, which the save keeps (VCard.header_of), where a
      # header rebuilt from form fields would drop the parameters no
      # field models, and macOS writes three TYPE parameters on one
      # TEL. The digest in the field's name is the row's address, and
      # a blank value removes the line — the state is unconditional,
      # a row standing only over a line there is to lose. Identical
      # duplicate lines share a digest and therefore a field name, and
      # Rack keeps the last value of a duplicated name — editing one of
      # a pair of byte-identical rows means blanking one, saving, then
      # editing the other.
      #: (String caption, type: String, name: String, value: String) -> void
      def value_row(caption, type:, name:, value:)
        label(class: "field", data: {blank_removes: true}) do
          span { caption }
          input(type:, name:, value:, placeholder: "removed on save")
        end
      end

      # The one row that saves to the model rather than the card's
      # bytes, so the prefill is Contact#birthday and not a reading
      # off the card — why, and why every shape the grammar admits is
      # editable here, is docs/plans/2026-09-07-web-birthday-editor.md.
      # It renders only over a held birthday: an empty row was an
      # attribute rendering nothing (docs/DESIGN.md), and a birthday
      # arrives through the add dialog like every other property. Every
      # standing row holds one, so the removal state rides on it
      # unconditionally.
      #: () -> void
      def birthday_row
        birthday = @contact.birthday
        return unless birthday

        div(class: "field", data: {blank_removes: true}) do
          span { "birthday" }
          div(class: "date-row") do
            birthday_controls(birthday)
            # The remove control: three blanks is the rule that
            # removes and this is its one-click spelling — @click
            # empties the row's controls, the blank rule and the
            # struck caption do the rest, and retyping the date is
            # the undo. Gloss's IconButton (the one sanctioned
            # class) carrying the Lucide x (Admin::Icon), its
            # aria-label the name the glyph cannot show; the card
            # UI's removal register — low-contrast at rest, danger
            # on hover — is admin.css's. The picker's own date input
            # is swept along by the bare `input` here, which is
            # right: what the calendar had staged is no longer what
            # the row says.
            clear = "$el.closest('.date-row').querySelectorAll('select, input').forEach(el => el.value = '')"
            button(type: "button", class: "icon-button", data_size: "sm",
                   aria_label: "Remove birthday", "@click": clear) do
              render Icon.new(:x)
            end
          end
        end
      end

      # The birthday row's controls, shared by the standing row and
      # the add dialog's — the three fields, their order, and why they
      # are three rather than one date input are
      # docs/plans/2026-09-07-web-birthday-editor.md, "The row", and
      # the picker beside them is
      # docs/plans/2026-09-15-a-picker-beside-the-birthday.md. The
      # same names for both callers is the point: a birthday needs no
      # digest, there being at most one, and the save reads either
      # caller's row identically. A nil birthday is the added row.
      #: (Birthday? birthday, ?focus: bool) -> void
      def birthday_controls(birthday, focus: false)
        select(name: "birthday[month]", aria_label: "month",
               "x-init": focus ? "$el.focus()" : nil) do
          option(value: "", selected: birthday&.month.nil?) { "month" }
          Date::MONTHNAMES.compact.each_with_index do |name, index|
            option(value: index + 1, selected: birthday&.month == index + 1) { name }
          end
        end
        input(type: "number", name: "birthday[day]", value: birthday&.day,
              min: 1, max: 31, placeholder: "day", aria_label: "day")
        input(type: "number", name: "birthday[year]", value: birthday&.year,
              min: 1, max: 9999, placeholder: "year", aria_label: "year")
        birthday_picker
      end

      # The calendar affordance: a date input the row never shows and
      # never submits, and the button that opens its native picker.
      # Why the picker writes the three fields instead of being one,
      # why the input is hidden out of flow rather than by
      # `display: none`, why it carries no name and sits outside both
      # the tab order and the accessibility tree, and why opening
      # syncs from the boxes with no guard for a partial birthday are
      # all docs/plans/2026-09-15-a-picker-beside-the-birthday.md.
      #
      # aria-hidden is spelled out rather than left bare: ARIA's
      # true/false attributes are enumerated, not HTML booleans, and
      # a present-but-empty one is not the same claim as "true" in
      # every reading of the spec. Icon writes the bare form and is
      # harmless doing it — a decorative svg inside a labelled button
      # contributes no name either way — but this is an input, and
      # an input that reaches the tree unlabelled is not harmless.
      #: () -> void
      def birthday_picker
        sync = "const r = $el.closest('.date-row'), n = r.querySelectorAll('input[type=number]'), " \
               "p = r.querySelector('input[type=date]'); " \
               "p.value = `${n[1].value.padStart(4, '0')}-${r.querySelector('select').value.padStart(2, '0')}" \
               "-${n[0].value.padStart(2, '0')}`; p.showPicker()"
        fill = "if (!$el.value) return; " \
               "const r = $el.closest('.date-row'), n = r.querySelectorAll('input[type=number]'), " \
               "[y, m, d] = $el.value.split('-'); " \
               "r.querySelector('select').value = +m; n[0].value = +d; n[1].value = +y"
        input(type: "date", tabindex: -1, aria_hidden: "true", "@change": fill)
        button(type: "button", class: "icon-button", data_size: "sm",
               aria_label: "Pick a birthday from a calendar", "@click": sync) do
          render Icon.new(:calendar)
        end
      end

      # An address row: the type's caption and a stack of component
      # fields in the value column — the multi-line value's own lines
      # (docs/DESIGN.md: a multi-line value breaks inside the value
      # column and stays in it). A div rather than the single-value
      # rows' label, because the row holds six controls and a label
      # names one — each input carries its placeholder as its
      # aria-label instead, and the caption is the type's. The digest
      # in each field's name is the row's address; the po box has no
      # field, and the save preserves its bytes. The removal state
      # rides only on a line with no po box: the save's removal is
      # blank throughout, po box included (CardForm.address_line), so
      # a line surviving by its po box alone cannot be removed from
      # this form at all — its row wears no state however blank it
      # renders.
      #: (Contact::Address address) -> void
      def address_row(address)
        div(class: "field", data: {blank_removes: address.po_box.nil?}) do
          span { Format.type_label(nil, address.types, "address") }
          div(class: "field-stack") do
            ADDRESS_FIELDS.each do |component, label|
              input(type: "text", name: "address[#{address.line.digest}][#{component}]",
                    value: address.public_send(component), placeholder: label, aria_label: label)
            end
          end
        end
      end

      # Where a property a contact does not have yet gets named —
      # docs/DESIGN.md's "a quiet add affordance opens a native dialog
      # that names the attribute types available." It holds no value,
      # so there is nothing staged out of sight and Cancel is a plain
      # hide with nothing to undo; Add is the only thing that changes
      # the form, and what it changes is visible in the card the
      # moment the popover closes.
      #
      # The radios share a `name` so they are one native group —
      # arrow-key navigation and "1 of n" come from that, not from
      # `x-model`, which only tells Alpine which one is picked. The
      # name is never form data: the dialog is outside the edit form
      # and has no form owner, so nothing submits it.
      #
      # A radiogroup rather than a fieldset, and no legend: the
      # dialog's header already names what is being picked, and a
      # legend under it read as a second heading for one control.
      # Gloss's `dialog > *` padding also outranks its `fieldset`
      # reset, and a legend renders above the padding box rather than
      # inside it, so the two stacked into a gap nothing asked for.
      def add_property_dialog
        dialog(id: "add-property", popover: "auto") do
          header { "Add a property" }
          div(class: "field-stack", role: "radiogroup", aria_label: "Type") do
            addable_types.each do |kind|
              # A label wrapping its own radio is Gloss's Radio, told
              # apart from Field structurally rather than by class.
              # The birthday's radio leaves the list once its row
              # stands — x-show rather than a template x-if, so the
              # native group keeps its shape and the option only
              # disappears.
              label("x-show": kind == "birthday" ? "!added.includes('birthday')" : nil) do
                input(type: "radio", name: "add-type", value: kind, "x-model": "type")
                plain kind
              end
            end
          end
          footer do
            button(type: "button", popovertarget: "add-property",
                   popovertargetaction: "hide") { "Cancel" }
            # Hiding the popover from script rather than with
            # `popovertargetaction`: a button cannot both run this
            # handler and carry the declarative hide, and the row has
            # to exist before the dialog goes away or `x-init`'s focus
            # lands on an element nobody can see. The guard on the
            # push is the birthday's: a hidden radio can stay the
            # model's pick (x-model holds its last value), so Add
            # itself refuses a second one — the row that cannot usefully
            # repeat, its fields a group Rack would collapse to the
            # last copy.
            button(type: "button", data: {variant: "primary"},
                   "@click": "(type !== 'birthday' || !added.includes('birthday')) && added.push(type); " \
                            "$el.closest('dialog').hidePopover()") { "Add" }
          end
        end
      end

      # A birthday leaves the list once the contact holds one, that
      # being the most a card carries. #birthday_row is the same guard
      # from the other side.
      #: () -> Array[String]
      def addable_types
        @contact.birthday ? ADDABLE_TYPES - ["birthday"] : ADDABLE_TYPES
      end
    end
  end
end
