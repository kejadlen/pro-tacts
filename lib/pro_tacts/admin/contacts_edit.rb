require "pro_tacts/admin/phlex"

require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /contacts/:id/edit — the editor
    # (docs/plans/2026-09-05-web-card-editor.md): an explicit mode
    # rather than an always-editable page, one form over the
    # properties the save knows how to address. The cardinality-1 set
    # — name, nickname, note — saves through VCard#replace under each
    # field; the phone, email, and address rows save through
    # VCard#substitute, each named by its line's digest. Birthday
    # arrives last, with its own doc.
    #
    # The fields prefill from the accessors' unescaped readings, and
    # blank equals absent on the way back (Web#edited_card), so write
    # and read agree on what an empty value means. The etag rides
    # along hidden — the snapshot guard's half, the POST's refusal
    # being the other. `autofocus` on the first field: this screen's
    # entry point is the name, not the header search.
    class ContactsEdit < Phlex::HTML
      # The property types the add dialog offers, in the order it
      # lists them — exactly the rows the save can insert
      # (docs/plans/2026-09-05-web-card-editor.md), because a type
      # listed here that the save cannot write would be a row that
      # silently does nothing. Each name is both the radio's value
      # and the row's field name: `new_<type>[]` for the single-value
      # kinds, `new_address[<i>][<component>]` for the structured
      # one, the bare [] unable to carry a component set (Rack
      # refuses a key after an empty one).
      ADDABLE_TYPES = %w[phone email address].freeze #: Array[String]
      private_constant :ADDABLE_TYPES

      # The address row's component fields, stacked in the value
      # column in the order an address form reads — RFC 2426 section
      # 3.2.1's own order minus the po box, which no screen shows and
      # the save splices around. Field name to placeholder: a
      # component is not an attribute and earns no type column of its
      # own, so the placeholder is the label and the conventional
      # order carries it.
      ADDRESS_FIELDS = [
        ["street", "street"],
        ["extended", "street 2"],
        ["locality", "city"],
        ["region", "region"],
        ["postal_code", "postal code"],
        ["country", "country"],
      ].freeze #: Array[[String, String]]
      private_constant :ADDRESS_FIELDS

      # @rbs @contact: Contact
      # @rbs @notice: String?
      # @rbs @first: String?
      # @rbs @last: String?

      #: (contact: Contact, ?notice: String?) -> void
      def initialize(contact:, notice: nil)
        @contact = contact
        @notice = notice
        # N's first two components (RFC 2426 section 3.1.2: family;
        # given) — the two fields the create dialog also asks for. The
        # remaining three are preserved byte-for-byte by the save's
        # raw splice (Web#n_line), never rendered here.
        family, given = contact.name_components || []
        @first = given
        @last = family
      end

      def view_template
        render Layout.new(title: "Edit #{@contact.name || @contact.id}", notice: @notice) do
          # The editor's Alpine scope, wrapping the record and the add
          # dialog both: the dialog names a type and the form grows a
          # row for it, so the two have to share state, and Alpine
          # scopes by ancestry. `added` is the list of types added
          # this pass, `type` is the radio's binding.
          div(x_data: "{ added: [], type: '#{ADDABLE_TYPES.first}' }") do
            # The caption-to-card block the details page uses (.record
            # in admin.css): the back link is this card's caption row,
            # and the row's one action sits at its right edge — the
            # same place, and the same shape, as the details page's
            # edit link. Each mode's row names the other thing you can
            # do to the record from it.
            div(class: "record") do
            div(class: "record-nav") do
              a(href: "/contacts/#{@contact.id}", class: "type-label") {
                "‹ #{@contact.name || @contact.id}"
              }
              button(type: "button", data_size: "sm",
                     popovertarget: "add-property") { "add property" }
            end
            div(class: "card") do
              div(class: "card-body") do
                form(action: "/contacts/#{@contact.id}", method: "post", class: "field-stack") do
                  input(type: "hidden", name: "etag", value: @contact.etag)
                  # The caption is an element rather than bare text
                  # because the row is a grid (admin.css): a text node
                  # would still land in the type column as an
                  # anonymous grid item, but nothing could then reach
                  # it, and the note's caption needs reaching.
                  label(class: "field") do
                    span { "First" }
                    input(type: "text", name: "first", value: @first,
                          required: true, autofocus: true)
                  end
                  label(class: "field") do
                    span { "Last" }
                    input(type: "text", name: "last", value: @last)
                  end
                  label(class: "field") do
                    span { "Nickname" }
                    input(type: "text", name: "nickname", value: @contact.nickname)
                  end
                  # A phone row edits its value and nothing else: the
                  # TYPE parameters ride in the line's own header,
                  # which the save keeps (VCard.header_of) — a header
                  # rebuilt from form fields would drop the parameters
                  # no field models, and macOS writes three TYPE
                  # parameters on one TEL. The digest in the field's
                  # name is the row's address, and a blank value
                  # removes the line. Identical duplicate lines share a
                  # digest and therefore a field name, and Rack keeps
                  # the last value of a duplicated name — editing one
                  # of a pair of byte-identical rows means blanking
                  # one, saving, then editing the other.
                  @contact.phones.each do |phone|
                    label(class: "field") do
                      span { phone.type || "phone" }
                      input(type: "tel", name: "phone[#{phone.line.digest}]", value: phone.value)
                    end
                  end
                  # An email row, the phone row's own shape over EMAIL.
                  @contact.emails.each do |email|
                    label(class: "field") do
                      span { email.type || "email" }
                      input(type: "email", name: "email[#{email.line.digest}]", value: email.value)
                    end
                  end
                  @contact.addresses.each { address_row(it) }
                  added_rows
                  label(class: "field") do
                    span { "Note" }
                    textarea(name: "note", rows: 4) { @contact.notes.to_s }
                  end
                  # Save is the form's submit; Cancel is navigation — a
                  # link in Gloss's `.btn` contract, which is what an
                  # anchor that acts like a button opts into.
                  div(class: "form-actions") do
                    button(type: "submit", data: {variant: "primary"}) { "Save" }
                    a(href: "/contacts/#{@contact.id}", class: "btn") { "Cancel" }
                  end
                end
              end
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
      # scaffold docs/DESIGN.md refuses, and a trailing one left over
      # from a row already filled is the same scaffold arriving late.
      # That verb — make a row, now, without a round trip — is what
      # CSS could not do and what Alpine is here for (see Layout).
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
            template("x-if": "kind !== 'address'") do
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
          end
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
      # field, and the save preserves its bytes.
      #: (Contact::Address address) -> void
      def address_row(address)
        div(class: "field") do
          span { address.type || "address" }
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
      # that names the attribute types available." It replaces the
      # blank add-row that used to sit in the stack, because that row
      # was an empty attribute with a caption on it and the card is
      # supposed to render the record's real weight. One row per type
      # would have been three of them by the time emails and addresses
      # land; one dialog is one row of chrome no matter how many types
      # it names.
      #
      # The dialog names a type and nothing else. It holds no value,
      # so there is nothing staged out of sight, and Cancel is a plain
      # hide with nothing to undo — Add is the only thing that changes
      # the form, and what it changes is visible in the card the
      # moment the popover closes.
      #
      # The three options are the three kinds of row the save can
      # insert; a fourth, birthday, arrives with its own doc.
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
            ADDABLE_TYPES.each do |kind|
              # A label wrapping its own radio is Gloss's Radio, told
              # apart from Field structurally rather than by class.
              label do
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
            # lands on an element nobody can see.
            button(type: "button", data: {variant: "primary"},
                   "@click": "added.push(type); $el.closest('dialog').hidePopover()") { "Add" }
          end
        end
      end
    end
  end
end
