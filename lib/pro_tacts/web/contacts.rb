require "pro_tacts/admin/card_form"
require "pro_tacts/admin/contact_dialog"
require "pro_tacts/admin/contacts_edit"
require "pro_tacts/admin/contacts_index"
require "pro_tacts/admin/contacts_show"
require "pro_tacts/admin/dashboard"
require "pro_tacts/change_id"

module ProTacts
  class Web < Roda
    # The card browser, one segment down from the page at the root:
    # /contacts/:id names what the id is without spending the whole
    # single-segment namespace on contact ids. Under the same auth
    # gate as the CardDAV routes — "a few family members, all
    # trusted" is the whole access model this app has, see README's
    # simplifying assumptions.
    hash_branch("contacts") do |r|
      # `r.is` because a bare verb block matches any remaining path in
      # Roda — without it, the collection's create would swallow the
      # record's apply, POST /contacts/:id below.
      r.is do
        # The whole-set listing, the one screen that browses the
        # contacts (docs/DESIGN.md, "The core idea").
        r.get do
          response["Content-Type"] = "text/html; charset=utf-8"
          Admin::ContactsIndex.call(contacts: store.contacts, groups: store.all_groups)
        end

        # The browser's create, from the dashboard's dialog: POST is
        # the one method the admin UI adds to the DAV set (see
        # config/puma.rb, whose list Puma replaces rather than
        # extends), and the collection is the resource a create
        # names. Stored through Store#put like any client write, so
        # the change log a sync token counts on lands with the card.
        # A nameless create is a dashboard re-render with a toast: the
        # browser cannot produce one (the dialog requires one name box
        # or the other, Admin::NamePair), so this is the backstop, and
        # a popover cannot be declared open in markup — the toast is
        # the refusal the
        # re-rendered page can actually show.
        r.post do
          first = r.params["first"].to_s.strip
          middle = r.params["middle"].to_s.strip
          last = r.params["last"].to_s.strip
          # A middle name is not one of the halves that make a name: the
          # form asks for it beside a pair it stands outside of
          # (Admin::NamePair), and nobody is known by their middle name
          # alone.
          if first.empty? && last.empty?
            dashboard(query: r.params["q"], notice: "A contact needs a name.")
          else
            id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
            store.put(id, Admin::CardForm.new_card(id, first, middle, last))
            r.redirect "/contacts/#{id}", 303
          end
        end
      end

      r.on String do |id|
        # The browser's edit of one contact
        # (docs/plans/2026-09-05-web-card-editor.md): an explicit
        # mode — GET renders the form, POST applies it, success is a
        # 303 back to the details page so the back button cannot
        # double-submit. POST stays the wire verb, the create's
        # precedent: HTML forms speak only GET and POST, and the
        # admin surface's one client is the form.
        r.get "edit" do
          contact = store.contact(id)

          # No match falls through to the empty-body 404 the
          # not_found handler fills in, same as the page below.
          if contact
            response["Content-Type"] = "text/html; charset=utf-8"
            Admin::ContactsEdit.call(contact:, back: edit_back(contact))
          end
        end

        # Membership from the contact's side, the groups dialog's save
        # (Admin::GroupDialog). Above the edit's POST, whose bare verb
        # block would match this path too.
        r.post "groups" do
          apply_groups(r, id)
        end

        r.post do
          apply_edit(r, id)
        end

        # The picture the avatars render (Admin::Avatar): decoded
        # bytes under their own content type, served from a route
        # rather than inlined as base64 so a page of avatars is a
        # page of cacheable image requests instead of ten 330 KB
        # payloads stitched into the HTML. The contact's etag, so a
        # picture changes exactly when its card does.
        r.get "photo" do
          contact = store.contact(id)

          # The views never point at a photo the card lacks, so a
          # contact with none is the 404 case above.
          if contact && (photo = contact.photo)
            response["Content-Type"] = photo.mime_type
            response["ETag"] = contact.etag
            photo.bytes
          end
        end

        r.get do
          contact = store.contact(id)

          contact_screen(contact) if contact
        end
      end
    end

    private

    # The dashboard GET and a refused create render the same page,
    # which is why the query travels both paths — a create refused
    # under a search re-renders the results it was refused over.
    #: (query: String?, ?notice: String?) -> String
    def dashboard(query:, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::Dashboard.call(
        recent: store.contacts_by_recency,
        upcoming: store.upcoming_birthdays(Admin::UpcomingBirthdays::LIMIT),
        query:,
        groups: store.all_groups,
        notice:,
      )
    end

    # The whole of the edit POST, a private method for the reason
    # Web#write_card is one, and its checks in the same order: the
    # request's own validity first, the conditionals on stored state
    # after.
    #
    # `refuse` renders the editor back with the notice — this page's
    # own screen by default; the walk renders its row's card in
    # place — and `land` is where a successful save redirects, the
    # contact's page by default.
    #: (untyped r, String id, ?refuse: ^(Contact, ?notice: String) -> String, ?land: String?) -> String?
    def apply_edit(r, id, refuse: ->(contact, notice:) { edit_screen(contact, notice:) }, land: nil)
      contact = store.contact(id)
      return if contact.nil?

      # N and FN are mandatory (RFC 2426 section 4), so a save blank
      # throughout is refused — the toast is the backstop, the form's
      # name pair (Admin::NamePair) being the browser's own refusal of
      # the same.
      first = r.params["first"].to_s.strip
      middle = r.params["middle"].to_s.strip
      last = r.params["last"].to_s.strip
      return refuse.call(contact, notice: "A contact needs a name.") if first.empty? && last.empty?

      # Request validity, standing with the name check rather than the
      # stored-state conditionals below (write_card's ordering rule). A
      # POST that carries no birthday group keeps the model, the phones'
      # is-a-Hash posture — this form's own save does when it rendered
      # no birthday row, and anything else never carried one; a group of
      # three blanks is the row's blank-equals-absent, a removal.
      birthday =
        if (fields = r.params["birthday"]).is_a?(Hash)
          begin
            Admin::CardForm.birthday(fields)
          rescue ArgumentError
            return refuse.call(contact, notice: "That birthday is not a shape a date can take.")
          end
        else
          contact.birthday
        end

      # The snapshot guard, the lost-update half If-Match gives DAV
      # clients (RFC 7232 section 3.1): the form carried the etag of
      # the card it was rendered from, and a contact that hashes
      # differently now was edited in between — another tab, or a
      # client sync — so applying this save over that one would revert
      # it. The refusal re-renders from the current card, so the screen
      # shows what changed; the check shares write_card's millisecond
      # race window between check and write, noted there.
      return refuse.call(contact, notice: "This contact changed since the page loaded; nothing was saved.") if r.params["etag"].to_s != contact.etag

      # The one state the birthday row cannot write, refused whole:
      # docs/plans/2026-09-07-web-birthday-editor.md, "The one hazard:
      # a card that carries its own BDAY", which also records the
      # migration not taken.
      if birthday && contact.stored.lines.any? { it.names?("BDAY") }
        return refuse.call(contact, notice: "This contact's card carries its own birthday spelling; nothing was saved.")
      end

      store.save_edit(id, Admin::CardForm.contact_card(contact, first, middle, last, r.params), birthday:)
      r.redirect land || "/contacts/#{id}", 303
    end

    # The dialog's save as what it toggled rather than the set it shows:
    # `was` is the boxes checked when the page loaded, so a group joined
    # or left elsewhere since stays as it is, and a stale page has
    # nothing to revert and no snapshot to refuse. Only ids naming a
    # group: Store#add_member reads the group with `sole`, so a doctored
    # one would be a 500 rather than the bad input it is. A `new` name
    # is a group the filter box offered to create, joined in the same
    # save; a blank one is none.
    #: (untyped r, String id) -> String?
    def apply_groups(r, id)
      contact = store.contact(id)
      return if contact.nil?

      known = store.group_choices.map(&:id)
      checked = ids_in(r.params["groups"]) & known
      was = ids_in(r.params["was"]) & known
      # The names the picker's offer committed, each made with this
      # save (Admin::GroupFilter::Named) — a tick is what commits a
      # name, so there is no single `new` riding the filter to read.
      names = ids_in(r.params["named"]).map(&:strip).reject(&:empty?)
      # The walk's row, when the dialog was opened from one
      # (Admin::ImportSaved's `land`): where a save returns to and a
      # refusal renders, so a look back is not a navigation away from
      # the walk.
      row = walk_row(r.params["land"].to_s)
      begin
        store.regroup(id, join: checked - was, leave: was - checked, create: names)
      rescue Sequel::UniqueConstraintViolation
        # A taken name (db/migrations/008_group_names.rb), refused with
        # the rest of the save in regroup's transaction. The page's own
        # list is what keeps the picker from offering a taken name, so
        # a save that finds one is looking at a list gone stale — the
        # name is asked of the store rather than of the form.
        clash = names.find { |name| store.group_choices.any? { it.name == name } }
        notice =
          if clash
            "Another group is already named #{clash}; nothing was saved."
          else
            "A group already holds one of those names; nothing was saved."
          end
        if row
          upload, index = row
          return card_screen(upload, index, notice:)
        end
        return contact_screen(contact, notice:)
      end
      r.redirect(row ? r.params["land"].to_s : "/contacts/#{id}", 303)
    end

    # A walk row's path (`/import/:upload/:index`), read back into its
    # parts when the groups dialog's save came from one. Only the
    # shape this server renders is honored: `land` is a form field,
    # and the redirect is not its to choose — a path aimed elsewhere
    # lands on the contact's own page as though none was sent.
    #: (String land) -> [String, Integer]?
    def walk_row(land)
      row = land.match(%r{\A/import/([a-z]+)/(\d+)\z})
      [row[1], Integer(row[2])] if row
    end

    # A form's list of ids, and none for a param absent or not a list.
    #: (untyped param) -> Array[String]
    def ids_in(param)
      param.is_a?(Array) ? param.map(&:to_s) : []
    end

    #: (Contact contact, ?notice: String) -> String
    def contact_screen(contact, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ContactsShow.call(
        contact:,
        groups: store.groups_of(contact.id),
        all_groups: store.group_choices,
        changes: store.changes_of(contact.id),
        notice:,
      )
    end

    #: (Contact contact, ?notice: String) -> String
    def edit_screen(contact, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ContactsEdit.call(contact:, notice:, back: edit_back(contact))
    end

    # The edit's way back, named by the route rather than left to the
    # view: the import's editor passes none, its navigation being the
    # list beside it.
    #: (Contact contact) -> [String, String]
    def edit_back(contact)
      ["/contacts/#{contact.id}", contact.name || contact.id]
    end
  end
end
