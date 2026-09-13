
require "pathname"
require "securerandom"

require "pro_tacts"
require "sentry-ruby"

require "rack/rewindable_input"
require "roda"

require "pro_tacts/admin/card_form"
require "pro_tacts/admin/contact_dialog"
require "pro_tacts/admin/contacts_edit"
require "pro_tacts/admin/contacts_index"
require "pro_tacts/admin/contacts_show"
require "pro_tacts/admin/device_setup"
require "pro_tacts/admin/groups_edit"
require "pro_tacts/admin/groups_index"
require "pro_tacts/admin/groups_show"
require "pro_tacts/debug_logger"
require "pro_tacts/contact"
require "pro_tacts/profile"
require "pro_tacts/store"
require "pro_tacts/tailscale_auth"
require "pro_tacts/unhandled_requests"
require "roda/plugins/dav_verbs"

module ProTacts
  class Web < Roda
    # @rbs @contacts: Array[Contact]?
    # @rbs @ctag: String?
    # @rbs @identity: TailscaleAuth::Identity
    # @rbs @book: Set[String]?

    # The vendored Gloss CSS and the admin app's own stylesheet (see
    # docs/DESIGN.md); relative to this file rather than $0 for the same
    # reason Store::MIGRATIONS is, and served by Roda's own `public`
    # plugin rather than a reverse proxy — there is no reverse proxy
    # here, `tailscale serve` hands requests straight to this app.
    PUBLIC_ROOT = Pathname.new(
      __dir__ #: String
    ).parent.parent / "public" #: Pathname

    # The store this app serves from. config.ru builds it and hands it in;
    # nothing here reaches for a global to find one, which is what lets a
    # test point the app at a throwaway database. Kept in Roda's own opts
    # rather than a class variable, so it is frozen with the app and a
    # write after that raises instead of quietly taking effect.
    #: (Store store) -> void
    def self.store=(store)
      opts[:store] = store
    end

    #: () -> Store
    def self.store
      opts.fetch(:store) do
        raise "no store: hand one to ProTacts::Web.store= before serving"
      end
    end

    # RewindableInput allows us to read the request body for Sentry logging
    # and then rewind it so the application can still access it.
    use Rack::RewindableInput::Middleware
    use Sentry::Rack::CaptureExceptions

    # Outside the route's identity gate (#unauthorized), and safe there
    # because a refusal is a 401, which it does not keep
    # (UnhandledRequests.capture?): a refused request is not missing
    # functionality, and recording one would write an unauthenticated
    # body to disk.
    use ProTacts::UnhandledRequests, directory: ProTacts.config.unhandled_dir

    # Outside the identity gate too, so a refused request is dumped with
    # the rest. That is the point of a debug log, which is off by default
    # and kept on a local machine.
    if ProTacts.config.debug?
      logger = ProTacts::DebugLogger.open_log(ProTacts.config.debug_log_path)
      use ProTacts::DebugLogger, logger: logger
    end

    plugin :all_verbs
    plugin :dav_verbs
    plugin :public, root: PUBLIC_ROOT.to_s
    plugin :hash_branches

    plugin :not_found do
      Sentry.capture_message("404 Not Found", level: :warning)
      "Not Found"
    end

    # The router's trunk: the identity gate, the static files, the admin
    # screens, and the root the admin and DAV halves share. The DAV
    # routes are hash_branches in lib/pro_tacts/web/dav.rb, run on this
    # same instance, so what the trunk sets they see.
    route do |r|
      # Every request names a tailnet user or is refused, the static
      # files included (ProTacts::TailscaleAuth).
      @identity = TailscaleAuth.identity(r.env) || unauthorized(r)

      r.public
      r.hash_branches

      # The card browser, one segment down from the page at the root:
      # /contacts/:id names what the id is without spending the whole
      # single-segment namespace on contact ids. Under the same auth
      # gate as the CardDAV routes — "a few family members, all
      # trusted" is the whole access model this app has, see README's
      # simplifying assumptions.
      r.on "contacts" do
        # The browser's create, from the dashboard's dialog: POST is
        # the one method the admin UI adds to the DAV set (see
        # config/puma.rb, whose list Puma replaces rather than
        # extends), and the collection is the resource a create
        # names. Stored through Store#put like any client write, so
        # the change log a sync token counts on lands with the card.
        # A nameless create is a dashboard re-render with a toast: the
        # browser cannot produce one (the dialog's first field is
        # required), so this is the backstop, and a popover cannot be
        # declared open in markup — the toast is the refusal the
        # re-rendered page can actually show. `r.is` because a bare
        # verb block matches any remaining path in Roda — without it,
        # the collection's create would swallow the record's apply,
        # POST /contacts/:id below.
        r.is do
          r.post do
            first = r.params["first"].to_s.strip
            last = r.params["last"].to_s.strip
            if first.empty? && last.empty?
              dashboard(query: r.params["q"], notice: "A contact needs a name.")
            else
              id = SecureRandom.uuid
              store.put(id, Admin::CardForm.new_card(id, first, last))
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
              Admin::ContactsEdit.call(contact:)
            end
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

            if contact
              response["Content-Type"] = "text/html; charset=utf-8"
              Admin::ContactsShow.call(contact:, groups: store.groups_of(id),
                                       changes: store.changes_of(id))
            end
          end
        end
      end

      # The group screens, the contacts' own shape: the collection's
      # GET and create, then a record's GET, its editor, and the POST
      # that applies it. What the writes rest on is
      # docs/plans/2026-09-09-group-edits-propagate.md. A create lands
      # on the editor, a new group being nothing until something is
      # added to it.
      r.on "groups" do
        r.is do
          r.get do
            response["Content-Type"] = "text/html; charset=utf-8"
            Admin::GroupsIndex.call(groups: store.all_groups)
          end

          r.post do
            name = r.params["name"].to_s.strip
            id = store.create_group(name: name.empty? ? nil : name)
            r.redirect "/groups/#{id}/edit", 303
          rescue Sequel::UniqueConstraintViolation
            # A taken `sync:` name, the one kind that must be unique
            # (db/migrations/007_sync_names.rb).
            response["Content-Type"] = "text/html; charset=utf-8"
            Admin::GroupsIndex.call(groups: store.all_groups, notice: "Another group is already named #{name}.")
          end
        end

        r.on String do |id|
          r.get "edit" do
            group = store.group(id)
            group_edit_screen(group) if group
          end

          r.post do
            apply_group_edit(r, id)
          end

          r.get do
            group = store.group(id)

            if group
              response["Content-Type"] = "text/html; charset=utf-8"
              Admin::GroupsShow.call(group:, members: members_of(group))
            end
          end
        end
      end

      # The configuration profile, served so the device reading this can
      # provision itself: until this route existed the only renderer was
      # the Rakefile, so putting the account on a phone meant running
      # rake on the machine holding the checkout and mailing the file
      # over. The screen and the document are separate paths because a
      # mobileconfig is not a page — the screen says what the download
      # will do, and only the link fires the install flow.
      #
      # The hostname is the request's rather than PRO_TACTS_HOSTNAME:
      # the address a device reached this app at is reachable from that
      # device by construction, where an environment variable is a claim
      # about some other machine's idea of where we live. It is the
      # client's Host header, which behind `tailscale serve` is serve's
      # own — and past the auth gate above, the only devices asking are
      # on the tailnet.
      r.on "setup" do
        r.is do
          r.get do
            response["Content-Type"] = "text/html; charset=utf-8"
            Admin::DeviceSetup.call(hostname: r.host, name: Profile.account_name)
          end
        end

        # The media type is what starts the install: a device offers to
        # install a profile because of what the response is, not what the
        # path is called. The path carries .mobileconfig anyway, so a
        # download that does land in a file system lands under the name
        # the rake task writes. No Content-Disposition — an attachment
        # disposition on this type is untested here, and the install flow
        # is the point.
        r.get "carddav.mobileconfig" do
          response["Content-Type"] = "application/x-apple-aspen-config"
          Profile.render(hostname: r.host)
        end
      end

      r.is "" do
        # The dashboard home: the one human-facing screen's home
        # (docs/DESIGN.md), a GET alongside the PROPFIND below it —
        # same path, disjoint verbs, and a browser's plain GET is no
        # DAV client's bootstrap. The create dialog rides along hidden
        # in the render (see Admin::ContactDialog).
        r.get do
          dashboard(query: r.params["q"])
        end

        r.propfind do
          current_user_principal("/")
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
      Admin::ContactsIndex.call(
        recent: store.contacts_by_recency,
        upcoming: store.upcoming_birthdays(Admin::UpcomingBirthdays::LIMIT),
        query:,
        groups: store.all_groups,
        notice:,
      )
    end

    # The refusal of a request that names nobody. A 401 must carry a
    # challenge (RFC 9110 section 15.5.2), and `Tailscale` is no
    # registered scheme: it tells the client that the credential is its
    # tailnet identity, which nothing it could send supplies.
    #: (Roda::RodaRequest r) -> bot
    def unauthorized(r)
      response.status = 401
      response["WWW-Authenticate"] = "Tailscale"
      response["Content-Type"] = "text/plain"
      response.write("Unauthorized: no Tailscale identity on this request.\n")
      r.halt
    end

    #: () -> Store
    def store
      self.class.store
    end

    # The whole of the edit POST, a private method for the same reason
    # write_card is one: a Roda route block cannot return early, so each
    # refusal is a value the block ends with rather than a branch it
    # exits. The checks run in write_card's order — the request's own
    # validity first, the conditionals on stored state after.
    #: (untyped r, String id) -> String?
    def apply_edit(r, id)
      contact = store.contact(id)
      return if contact.nil?

      # N and FN are mandatory (RFC 2426 section 4), so a save blank
      # throughout is refused — the toast is the backstop, the form's
      # required field being the browser's own refusal of the same.
      first = r.params["first"].to_s.strip
      last = r.params["last"].to_s.strip
      return edit_screen(contact, notice: "A contact needs a name.") if first.empty? && last.empty?

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
            return edit_screen(contact, notice: "That birthday is not a shape a date can take.")
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
      return edit_screen(contact, notice: "This contact changed since the page loaded; nothing was saved.") if r.params["etag"].to_s != contact.etag

      # The one state the birthday row cannot write, refused whole:
      # docs/plans/2026-09-07-web-birthday-editor.md, "The one hazard:
      # a card that carries its own BDAY", which also records the
      # migration not taken.
      if birthday && contact.stored.lines.any? { it.names?("BDAY") }
        return edit_screen(contact, notice: "This contact's card carries its own birthday spelling; nothing was saved.")
      end

      store.rewrite(id, Admin::CardForm.contact_card(contact, first, last, r.params), birthday:)
      r.redirect "/contacts/#{id}", 303
    end

    # The group editor's POST, #apply_edit's shape over a group: the
    # snapshot guard, then the lines the form splices
    # (Admin::CardForm.group_lines), and one store write for the lot.
    #: (untyped r, String id) -> String?
    def apply_group_edit(r, id)
      group = store.group(id)
      return if group.nil?

      if r.params["version"].to_s != group.version
        return group_edit_screen(group, notice: "This group changed since the page loaded; nothing was saved.")
      end

      # Only ids that name a card: a membership row is a foreign key,
      # and a doctored id is ordinary bad input rather than a 500. A
      # POST carrying no list keeps the membership it found, the
      # phones' is-a-Hash posture (Admin::GroupsEdit).
      submitted = r.params["members"]
      members =
        if submitted.is_a?(Array)
          submitted.map(&:to_s) & store.contacts.map(&:id)
        else
          group.members
        end #: Array[String]

      begin
        store.edit_group(id, name: r.params["name"].to_s, lines: Admin::CardForm.group_lines(group, r.params), members:)
      rescue Sequel::UniqueConstraintViolation
        # A taken `sync:` name (db/migrations/007_sync_names.rb). The save
        # is one transaction, so nothing of it landed.
        return group_edit_screen(group, notice: "Another group is already named #{r.params['name']}; nothing was saved.")
      end
      r.redirect "/groups/#{id}", 303
    end

    #: (Store::Group group, ?notice: String) -> String
    def group_edit_screen(group, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::GroupsEdit.call(group:, notice:)
    end

    # A group's members as contacts, in the listing's own order.
    #: (Store::Group group) -> Array[Contact]
    def members_of(group)
      store.contacts.select { group.members.include?(it.id) }
    end

    #: (Contact contact, ?notice: String) -> String
    def edit_screen(contact, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ContactsEdit.call(contact:, notice:)
    end
  end
end

# The branches reopen Web, so they load once the plugins they call are in.
require "pro_tacts/web/dav"
