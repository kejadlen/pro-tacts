
require "pathname"
require "securerandom"

require "pro_tacts"
require "sentry-ruby"

require "rack/rewindable_input"
require "nokogiri"
require "roda"

require "pro_tacts/admin/contact_dialog"
require "pro_tacts/admin/contacts_edit"
require "pro_tacts/admin/contacts_index"
require "pro_tacts/admin/contacts_show"
require "pro_tacts/admin/device_setup"
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

    # The vendored Gloss CSS and the admin app's own stylesheet (see
    # docs/DESIGN.md); relative to this file rather than $0 for the same
    # reason Store::MIGRATIONS is, and served by Roda's own `public`
    # plugin rather than a reverse proxy — there is no reverse proxy
    # here, `tailscale serve` hands requests straight to this app.
    PUBLIC_ROOT = Pathname.new(
      __dir__ #: String
    ).parent.parent / "public" #: Pathname

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

    # Ahead of the debug logger on purpose: an unauthenticated request should
    # not get its body dumped to the log.
    use ProTacts::TailscaleAuth

    # Below the auth gate: a refused request is not missing functionality,
    # and recording one would write an unauthenticated body to disk.
    use ProTacts::UnhandledRequests, directory: ProTacts.config.unhandled_dir

    if ProTacts.config.debug?
      logger = ProTacts::DebugLogger.open_log(ProTacts.config.debug_log_path)
      use ProTacts::DebugLogger, logger: logger
    end

    plugin :all_verbs
    plugin :dav_verbs
    plugin :public, root: PUBLIC_ROOT.to_s

    plugin :not_found do
      Sentry.capture_message("404 Not Found", level: :warning)
      "Not Found"
    end

    # Four specs meet in this router: WebDAV itself (RFC 4918), the
    # CardDAV profile on top of it (RFC 6352), collection sync (RFC 6578),
    # and service discovery (RFC 6764). Each handler cites its section, and
    # the texts are vendored under docs/rfcs to check them against.
    route do |r|
      r.public

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
              store.put(id, new_contact_card(id, first, last))
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
              Admin::ContactsShow.call(contact:, groups: store.groups_of(id))
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
            Admin::DeviceSetup.call(hostname: r.host, name: Profile::DEFAULT_NAME)
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

        # DAV:current-user-principal (RFC 5397 section 3) — what a client
        # asks the root for to find the principal it is acting as.
        r.propfind do
          response["Content-Type"] = "text/xml"
          response.status = 207

          <<~XML
            <?xml version="1.0" encoding="UTF-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/</d:href>
                <d:propstat>
                  <d:prop>
                    <d:current-user-principal>
                      <d:href>/dav/principal/</d:href>
                    </d:current-user-principal>
                  </d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
          XML
        end
      end

      # The "carddav" well-known URI (RFC 6764 section 5, registered in
      # section 9.1.2), the start of a client's bootstrap.
      r.on ".well-known/carddav" do
        r.propfind do
          response["Content-Type"] = "text/xml"
          response.status = 207

          <<~XML
            <?xml version="1.0" encoding="UTF-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/.well-known/carddav</d:href>
                <d:propstat>
                  <d:prop>
                    <d:current-user-principal>
                      <d:href>/dav/principal/</d:href>
                    </d:current-user-principal>
                  </d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
          XML
        end

        # RFC 6764 section 5 forbids putting the service itself here and
        # requires a redirect to the real context path; 301 is one of the
        # codes it names.
        r.get do
          r.redirect "/dav/principal/", 301
        end
      end

      r.on "dav" do
        # "addressbook" in the DAV header is how a client detects CardDAV
        # support (RFC 6352 section 6.1); the header is RFC 4918 section 10.1.
        r.options do
          response["DAV"] = "addressbook"
          response["Allow"] = "OPTIONS, PROPFIND, REPORT, PUT, DELETE"
          ""
        end

        # CARDDAV:addressbook-home-set (RFC 6352 section 7.1.1) is the
        # hop from principal to collection.
        r.on "principal" do
          r.propfind do
            response["Content-Type"] = "text/xml"
            response.status = 207

            <<~XML
              <?xml version="1.0" encoding="UTF-8"?>
              <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
                <d:response>
                  <d:href>/dav/principal/</d:href>
                  <d:propstat>
                    <d:prop>
                      <card:addressbook-home-set>
                        <d:href>/dav/addressbook/</d:href>
                      </card:addressbook-home-set>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              </d:multistatus>
            XML
          end
        end

        r.on "addressbook" do
          r.propfind do
            body = request.body.read
            request.body.rewind

            response["Content-Type"] = "text/xml"
            response.status = 207

            # PROPFIND is RFC 4918 section 9.1, its Depth header section
            # 10.2, and the 207 body it returns section 13.
            depth = request.env.fetch("HTTP_DEPTH", "infinity")

            etag_only = body.include?("getetag") && !body.include?("displayname") && !body.include?("resourcetype")

            # The collection self-entry is omitted from an etag-only ask
            # until a client is found to need it.
            collection_response = ""
            unless etag_only
              # Every property in this body and where it comes from:
              # DAV:resourcetype, which an address book collection MUST report
              # as both collection and addressbook (RFC 6352 section 5.2);
              # DAV:supported-report-set (RFC 3253 section 3.1.5), which RFC
              # 6578 section 3.2 requires list sync-collection;
              # DAV:sync-token (RFC 6578 section 4); and
              # DAV:current-user-privilege-set (RFC 3744 section 5.4), which
              # RFC 6352 section 7 requires of a CardDAV server. getctag alone
              # is not standardized — an Apple CalendarServer extension in the
              # calendarserver.org namespace, kept because macOS polls it.
              #
              # The privileges are advertised ahead of the methods
              # granting some of them. macOS Contacts asks for this
              # property on every poll and attempts no write without it,
              # so claiming them is what makes the client send writes at
              # all — the PUT they prompted was what log/unhandled
              # captured them for. DAV:write covers PUT and PROPPATCH
              # (RFC 3744 section 3.2), and PUT is the one of the pair
              # answered; DAV:unbind is removing a member from the
              # collection (section 3.10), which DELETE answers.
              # DAV:bind is adding one (section 3.9), and the create it
              # names — POST to the collection with DAV:add-member — has
              # no route: PUT to the member URI is how both clients
              # create, so nothing has asked for it.
              collection_response = <<~XML
                <d:response>
                  <d:href>/dav/addressbook/</d:href>
                  <d:propstat>
                    <d:prop>
                      <d:resourcetype>
                        <d:collection/>
                        <card:addressbook/>
                      </d:resourcetype>
                      <d:supported-report-set>
                        <d:supported-report>
                          <d:report><d:sync-collection/></d:report>
                        </d:supported-report>
                      </d:supported-report-set>
                      <cs:getctag>#{ctag}</cs:getctag>
                      <d:sync-token>#{sync_token}</d:sync-token>
                      <d:current-user-privilege-set>
                        <d:privilege><d:read/></d:privilege>
                        <d:privilege><d:write/></d:privilege>
                        <d:privilege><d:bind/></d:privilege>
                        <d:privilege><d:unbind/></d:privilege>
                      </d:current-user-privilege-set>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              XML
            end

            members = depth == "0" ? "" : contacts.map { etag_response(it) }.join

            <<~XML
              <?xml version="1.0" encoding="UTF-8"?>
              <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/">
                #{collection_response}
                #{members}
              </d:multistatus>
            XML
          end

          r.report do
            body = request.body.read
            request.body.rewind

            response["Content-Type"] = "text/xml"
            response.status = 207

            doc = Nokogiri::XML(body)
            doc.remove_namespaces!

            # A body that is not XML parses to a document with no root.
            # There is no report to dispatch on, so raise and let it 500
            # rather than answer as though nothing was asked for.
            root = doc.root
            raise ArgumentError, "REPORT body is not XML" if root.nil?

            # Each branch renders the whole response body: a Roda route
            # block cannot return early, so the unsupported case has to be
            # a value like the others rather than a return.
            case root.name
            when "sync-collection"
              # DAV:sync-collection (RFC 6578 section 3.2): the members
              # added, changed, or removed since the token the client
              # holds, and the token naming the state the answer reaches.
              # The warm-sync ask is etag-only; a changed etag sends the
              # client back through multiget, so no address-data here.
              #
              # The token carries the change log's sequence (see
              # #sync_token), and the delta is the log after it: one
              # response per member, the net of everything it did in the
              # window — a member put twice since the token answers once,
              # at its current etag, the multiple-changes case section 3.5
              # allows one response for. A member whose net is a removal
              # answers as section 3.2 spells it: href and 404, no
              # propstat.
              #
              # Depth stays unread though the section defines the report
              # only at 0: macOS sends Depth: 1 (fixture 08), and 400-ing
              # the one real client over a header it ignores serves the
              # letter over the exchange. sync-level likewise — 1 and
              # infinite are the same answer here, the collection has no
              # member collections (section 3.3).
              token = doc.xpath("//sync-token").first&.text.to_s.strip
              if token.empty?
                # No token is the initial sync: every member, changed
                # (section 3.4).
                multistatus(contacts.map { etag_response(it) }, sync_token:)
              elsif (sequence = token[%r{\Ahttp://pro-tacts/sync/(\d+)\z}, 1]) &&
                  sequence.to_i <= store.latest_sequence
                net = store.changes(after: sequence.to_i).map { it.card_id }.uniq
                responses = net.map { |id|
                  contact = contacts.find { it.id == id }
                  contact ? etag_response(contact) : missing_response(contact_href(id))
                }
                multistatus(responses, sync_token:)
              else
                # A token this server never issued, or one naming a state
                # past the present: the section's DAV:valid-sync-token
                # precondition, marshalled per RFC 4918 section 16. 410
                # rather than 403 because its fallback is a full resync —
                # the request will not always fail, and the state the
                # token names is gone.
                response.status = 410

                <<~XML
                  <?xml version="1.0" encoding="UTF-8"?>
                  <d:error xmlns:d="DAV:">
                    <d:valid-sync-token/>
                  </d:error>
                XML
              end
            when "addressbook-multiget"
              # CARDDAV:addressbook-multiget (RFC 6352 section 8.7); the
              # address-data the client asks for is section 10.4.
              wants_cards = doc.xpath("//address-data").any?

              multistatus(doc.xpath("//href").map { it.text }.map { |requested|
                id = requested[%r{\A/dav/addressbook/([^/]+)\.vcf\z}, 1]
                contact = id && contacts.find { it.id == id }

                if contact
                  wants_cards ? card_response(contact) : etag_response(contact)
                else
                  missing_response(requested)
                end
              })
            else
              # The DAV:supported-report precondition on REPORT (RFC 3253
              # section 3.6) — the report asked for has to be one the
              # resource supports. Answering an unsupported report with an
              # empty 207 reads to the client as a successful empty result,
              # and to us as nothing at all: 207 is not a status
              # UnhandledRequests captures, so the one signal that a client
              # wanted something unimplemented never fired.
              #
              # 403 with the precondition named in a DAV:error body is the
              # marshalling RFC 4918 section 16 defines, and 403 is its
              # "will always fail, do not repeat" case. addressbook-query
              # (RFC 6352 section 8.6) is the report this rejects today;
              # macOS Contacts has never sent one.
              response.status = 403

              <<~XML
                <?xml version="1.0" encoding="UTF-8"?>
                <d:error xmlns:d="DAV:">
                  <d:supported-report/>
                </d:error>
              XML
            end
          end

          # Read on its own rather than through the collection: serving
          # one href has no reason to load every other contact first.
          r.get String do |filename|
            contact = store.contact(filename.delete_suffix(".vcf"))

            if contact
              response["Content-Type"] = "text/vcard; charset=utf-8"
              # RFC 7232 section 2.3; must match the getetag reported for
              # this contact in PROPFIND and REPORT.
              response["ETag"] = contact.etag
              contact.vcard.to_s
            end
          end

          # PUT to an unmapped URI creates the card there and PUT to a
          # mapped one replaces it (RFC 6352 section 6.3.2). macOS
          # creates with If-None-Match: * and a UUID it mints into both
          # the URI and the card's UID, and updates with If-Match
          # carrying the strong etag it was last served — see
          # docs/macos-contacts.md, "What a write looks like on the wire".
          r.put String do |filename|
            id = filename.delete_suffix(".vcf")
            # A last segment that is not this server's <id>.vcf shape
            # cannot address a resource here, created or read — the
            # same fall-through-to-404 the GET handler gives it.
            write_card(id) if id.match?(Contact::ID_FORMAT)
          end

          # DELETE removes the card at the member URI (RFC 4918 section
          # 9.6) — the DAV:unbind privilege the collection advertises,
          # and what iOS sends when a contact is deleted on the phone.
          r.delete String do |filename|
            id = filename.delete_suffix(".vcf")
            remove_card(id) if id.match?(Contact::ID_FORMAT)
          end
        end
      end
    end

    private

    # Read once per request — Roda builds a fresh app instance for each
    # one — from the store the whole process shares. Reading a family
    # address book per request is cheap and can never serve a stale one.
    #: () -> Array[Contact]
    def contacts
      @contacts ||= store.contacts
    end

    #: () -> String
    def ctag
      @ctag ||= store.ctag
    end

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
        notice:,
      )
    end

    # Sync tokens are opaque to the client (RFC 6578 section 3); the URI
    # form is conventional. Built on the ctag so a client polling either
    # one sees changes at the same points.
    #: () -> String
    def sync_token
      "http://pro-tacts/sync/#{ctag}"
    end

    #: () -> Store
    def store
      self.class.store
    end

    # The whole of the PUT route: a private method because a Roda route
    # block cannot return early, so each refusal is a value the block
    # ends with rather than a branch it exits. The checks run in the
    # order RFC 7232 section 5 sets for a request with preconditions —
    # the request's own validity first, the conditionals on stored
    # state after — so a card that cannot be stored hears
    # CARDDAV:valid-address-data even when its If-Match is stale too.
    #: (String id) -> String?
    def write_card(id)
      # CARDDAV:supported-address-data (RFC 6352 section 6.3.2.1): what
      # arrived must be a vCard, and text/vcard is the one media type
      # this server stores. Asked before the body is read because it is
      # a question about the request, not about what the request
      # carried.
      return precondition("supported-address-data") unless request.media_type == "text/vcard"

      # Decoding the body, both halves of it: Rack requires input in
      # ASCII-8BIT and Rack::RewindableInput enforces it again, so the
      # bytes are relabelled rather than converted — untouched — and the
      # label is checked honest in the same breath, because a
      # force_encoding nobody validates is a lie every later reader
      # inherits. That the bytes are not the UTF-8 the media type
      # promised is a fact about this body, not about any card, which is
      # why it is settled here and VCard is never handed the question
      # (CARDDAV:valid-address-data, RFC 6352 section 6.3.2.1). Left
      # unsettled it would surface as a 500 out of SQLite on the insert,
      # past the point where the client could be told what was wrong.
      # Paths need no counterpart: Puma hands PATH_INFO over still
      # percent-encoded, so an id off the wire is ASCII.
      vcard = request.body.read.force_encoding(Encoding::UTF_8)
      return precondition("valid-address-data") unless vcard.valid_encoding?

      # CARDDAV:valid-address-data again, on the card this time: the
      # envelope RFC 2426 section 4 requires. That is the whole test. A
      # line inside it this parser cannot read is not grounds for
      # refusing the card: RFC 6352 section 6.3.2.2 has the server keep
      # what it does not understand, and it is kept — the stored bytes
      # are what goes back out.
      card = VCard.new(vcard)
      return precondition("valid-address-data") unless card.card?

      # CARDDAV:no-uid-conflict: the submitted UID must not belong to a
      # different resource, and a mapped URI must not be overwritten by
      # a card carrying a different UID. Here the id is the card's UID
      # (see Contact), so both clauses come down to: the card carries a
      # UID naming the resource being written, and no other card claims
      # it. The href in the body is the SHOULD that section attaches to
      # the first clause — report where the UID already lives.
      uid = card.uid
      owner = uid && store.card_id_with_uid(uid)
      return precondition("no-uid-conflict", owner) if uid != id || owner && owner != id

      existing = store.contact(id)

      # The lost-update conditionals, RFC 7232 sections 3.1 and 3.2.
      # macOS sends If-Match on updates and If-None-Match: * on creates;
      # a PUT carrying neither is unconditional and allowed to proceed.
      if_match = request.env["HTTP_IF_MATCH"]
      return plain_412 if if_match && !if_match_satisfied?(if_match, existing)

      if_none_match = request.env["HTTP_IF_NONE_MATCH"]
      return plain_412 if if_none_match && if_none_match_failed?(if_none_match, existing)

      report_unreadable_lines(card)
      report_broken_assumptions(card)

      stored = store.put(id, vcard)
      response.status = existing ? 204 : 201
      # A strong ETag belongs on the answer only when what was stored is
      # the submitted bytes, octet for octet — the one case RFC 6352
      # section 6.3.2.3 lets a client rely on the tag it gets back, and
      # anywhere else it forbids one outright. A birthday is subtracted
      # from the card before storage and composed back in on read, so a
      # PUT that carried one stores a different card than it was handed
      # and the client refetches; a card with nothing to subtract still
      # stores octet for octet and still gets the tag.
      response["ETag"] = stored.etag if stored.vcard.to_s == vcard

      # A returned "" would land in the body and pin text/html and
      # content-length onto the 204, which a bodyless status must not
      # carry (Rack 3's lint rejects both); nil leaves it bodyless.
      nil
    end

    # The whole of the DELETE, a private method for write_card's reason:
    # a Roda route block cannot return early.
    #: (String id) -> String?
    def remove_card(id)
      # An unmapped URI is a 404, not a silent success: RFC 4918 section
      # 9.6 gives DELETE no idempotent status, and a client deleting what
      # it believes exists is owed the disagreement. Falls through to the
      # not_found handler the way the GET and PUT of a bad id do.
      existing = store.contact(id)
      return unless existing

      # The lost-update conditional, RFC 7232 section 3.1, on the same
      # terms the PUT gets it: a client that names the representation it
      # means to remove must not remove one that changed underneath it.
      # No recorded session has sent one on a DELETE — the iOS delete
      # carried none, which section 3.1 leaves unconditional and
      # allowed, and macOS has sent no DELETE at all. Answered anyway,
      # because ignoring the header is the lost update it exists to
      # refuse, and the PUT's own check is right here to reuse.
      if_match = request.env["HTTP_IF_MATCH"]
      return plain_412 if if_match && !if_match_satisfied?(if_match, existing)

      # The change-log entry Store#delete leaves in the same transaction
      # is what a syncing client is told: sync-collection answers a
      # removed member as href plus 404 (#missing_response).
      store.delete(id)
      response.status = 204

      # Bodyless for the 204, write_card's reason.
      nil
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
            parse_birthday(fields)
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

      store.rewrite(id, edited_card(contact, first, last, r.params).to_s, birthday:)
      r.redirect "/contacts/#{id}", 303
    end

    #: (Contact contact, ?notice: String) -> String
    def edit_screen(contact, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ContactsEdit.call(contact:, notice:)
    end

    # A created contact's card: the envelope RFC 2426 section 4
    # requires — BEGIN, VERSION, and the N and FN that section makes
    # mandatory — plus the UID this server's id model is (see
    # Contact). Nothing else: a created card has no prior octets to
    # preserve, and every other property arrives by editing the
    # record later. The names escape, because a name is text — a
    # comma or semicolon in one must not read as structure (RFC 2426
    # section 2.4.2).
    #: (String id, String first, String last) -> String
    def new_contact_card(id, first, last)
      "BEGIN:VCARD\r\nVERSION:3.0\r\n" \
        "N:#{VCard.escape(last)};#{VCard.escape(first)};;;\r\n" \
        "FN:#{VCard.escape([first, last].reject(&:empty?).join(" "))}\r\n" \
        "UID:#{id}\r\n" \
        "END:VCARD\r\n"
    end

    # The surgical save — the hazard it exists to remove, the
    # blank-equals-absent rule, and why REV is left alone are
    # docs/plans/2026-09-05-web-card-editor.md.
    #: (Contact contact, String first, String last, Hash[String, untyped] params) -> VCard
    def edited_card(contact, first, last, params)
      nickname = params["nickname"].to_s.strip
      note = params["note"].to_s.strip

      # The rows are read off the contact's own card, the one the form
      # rendered (Admin::ContactsEdit) and the one this save splices:
      # a line a group lends is on neither, so no digest here can name
      # one and no save can copy a group's value onto its member
      # (Contact#own).
      own = contact.own

      card = contact.stored
      card = card.replace("N", [n_line(card, first, last)])
      card = edited_fn(contact, card, first, last)
      card = card.replace("NICKNAME", text_lines("NICKNAME", nickname))
      card = card.replace("NOTE", text_lines("NOTE", note))
      card = edited_phones(own, card, params)
      card = edited_emails(own, card, params)
      edited_addresses(own, card, params)
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
    #: (Contact contact, VCard card, Hash[String, untyped] params) -> VCard
    def edited_phones(contact, card, params)
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
          card = card.substitute(
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
      card.insert(added)
    end

    # #edited_phones' walk, over EMAIL.
    #: (Contact contact, VCard card, Hash[String, untyped] params) -> VCard
    def edited_emails(contact, card, params)
      rows = params["email"]
      if rows.is_a?(Hash)
        contact.emails.each do |email|
          property = email.line.property
          next if property.nil?

          submitted = rows[email.line.digest]
          next if submitted.nil? || submitted.to_s.strip == email.value

          value = submitted.to_s.strip
          card = card.substitute(
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
      card.insert(added)
    end

    # #edited_phones' walk, over a row that is six fields rather than
    # one (Admin::ContactsEdit). Removal is the reader's own rule
    # (Contact#address_of): a row blank throughout, po box included,
    # removes the line, where a partially blanked one keeps it —
    # partial blanks are legal empty components.
    #: (Contact contact, VCard card, Hash[String, untyped] params) -> VCard
    def edited_addresses(contact, card, params)
      rows = params["address"]
      if rows.is_a?(Hash)
        contact.addresses.each do |address|
          property = address.line.property
          next if property.nil?

          submitted = rows[address.line.digest]
          next if !submitted.is_a?(Hash) || address_unchanged?(address, submitted)

          line = address_line(address, submitted)
          card = card.substitute(address.line.digest, line ? [line] : [])
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
      card.insert(added.filter_map { address_line(nil, it) })
    end

    #: (Contact::Address address, untyped submitted) -> bool
    def address_unchanged?(address, submitted)
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
    def address_line(address, submitted)
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
    def parse_birthday(fields)
      year = birthday_component(fields["year"])
      month = birthday_component(fields["month"])
      day = birthday_component(fields["day"])
      return if year.nil? && month.nil? && day.nil?

      Birthday.new(year:, month:, day:)
    end

    # One component off the wire: nil for blank, the integer it names
    # otherwise. Digits only — a month select and ranged number inputs
    # are the browser's own constraint, and this is the server's.
    #: (untyped submitted) -> Integer?
    def birthday_component(submitted)
      value = submitted.to_s.strip
      return nil if value.empty?
      raise ArgumentError, "not a number a birthday holds: #{value.inspect}" unless value.match?(/\A\d{1,4}\z/)

      value.to_i
    end

    # A text property's replacement lines: the escaped value (RFC 2426
    # section 2.4.2 — the value is text, the line is structure), or none
    # at all — blank equals absent, the whole-property rule.
    #: (String name, String value) -> Array[String]
    def text_lines(name, value)
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
    #: (Contact contact, VCard card, String first, String last) -> VCard
    def edited_fn(contact, card, first, last)
      family, given = contact.name_components || []
      named = card.properties.any? { it.name.casecmp?("FN") }
      return card if named && first == given.to_s && last == family.to_s

      card.replace("FN", ["FN:#{VCard.escape([first, last].reject(&:empty?).join(" "))}\r\n"])
    end

    # N's replacement line. The first two components are the form's;
    # the remaining three — additional, prefixes, suffixes (RFC 2426
    # section 3.1.2) — rejoin byte for byte, which is what the splice
    # over the still-escaped value buys
    # (docs/plans/2026-09-05-web-card-editor.md). A card with no N a
    # form can read splices into a bare five-component value; one
    # short of five is padded, the same empties a whole-N writer
    # would leave.
    #: (VCard card, String first, String last) -> String
    def n_line(card, first, last)
      property = card.properties.find { it.name.casecmp?("N") }
      components = [] #: Array[String]
      components.replace(VCard.split_raw_components(property.value)) if property
      components << "" while components.length < 5
      components[0] = VCard.escape(last)
      components[1] = VCard.escape(first)
      "N:#{components.join(";")}\r\n"
    end

    # A card that breaks one of the parser's assumptions is not bad
    # input, it is news that the assumption is wrong and every
    # simplification resting on it is now suspect — an error, where a
    # line that merely would not read is ordinary bad input and warns
    # instead (report_unreadable_lines, below). The card is accepted,
    # stored, and served either way, and a line that will not read
    # costs it only its index rows.
    #
    # Here rather than in the parser, which is where the break is
    # found: a read happens on every look at a card — the admin index
    # reads every contact on every page load — and one bad card must
    # not alert once per page view. An arrival is the event worth a
    # message, and a PUT is the only arrival there is. The message
    # carries no card content (ProTacts::SentryScrubber's line); the
    # admin view shows the card raw.
    #: (VCard card) -> void
    def report_broken_assumptions(card)
      broken = card.lines.count { it.broke_assumption? }
      return if broken.zero?

      Sentry.capture_message(
        "a submitted card broke #{broken} parser assumption(s) about what macOS Contacts sends",
        level: :error,
      )
    end

    # The ordinary half of the arrival reports: a line that would not
    # read is bad input rather than news, so it warns — the level and
    # the no-card-content line the store's BDAY reports already use.
    # BrokenAssumption lines are excluded, so a line reports once; why
    # this lives at the PUT is the comment above, and holds for both.
    #: (VCard card) -> void
    def report_unreadable_lines(card)
      unreadable = card.lines.count { it.unreadable? }
      return if unreadable.zero?

      Sentry.capture_message(
        "a submitted card carried #{unreadable} line(s) that would not read — stored verbatim, missing from the index",
        level: :warning,
      )
    end

    # A 412 whose body names the CardDAV precondition that failed, in
    # the DAV:error form RFC 4918 section 16 defines; the element names
    # are RFC 6352 section 6.3.2.1's, qualified by the card: namespace
    # the body declares. no-uid-conflict carries the conflicting card's
    # href when there is one.
    #: (String element, ?String? conflict_id) -> String
    def precondition(element, conflict_id = nil)
      named = if conflict_id
        "<card:#{element}><d:href>#{contact_href(conflict_id)}</d:href></card:#{element}>"
      else
        "<card:#{element}/>"
      end
      response.status = 412

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <d:error xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
          #{named}
        </d:error>
      XML
    end

    # A bare 412: these failures are HTTP's own conditionals (RFC 7232),
    # not a WebDAV precondition with an element to name in a body.
    #: () -> String
    def plain_412
      response.status = 412
      ""
    end

    # RFC 7232 section 3.1: If-Match passes when the current etag is one
    # of those listed, or, for `*`, when there is a current
    # representation at all.
    #: (String header, Contact? existing) -> bool
    def if_match_satisfied?(header, existing)
      return !existing.nil? if header.strip == "*"

      !existing.nil? && header.split(",").map(&:strip).include?(existing.etag)
    end

    # RFC 7232 section 3.2: If-None-Match fails a non-GET request when
    # the current etag is one of those listed, or, for `*`, whenever the
    # resource exists. The create — If-None-Match: * against an unmapped
    # URI — is the case CardDAV clients send (RFC 6352 section 6.3.2).
    #: (String header, Contact? existing) -> bool
    def if_none_match_failed?(header, existing)
      return !existing.nil? if header.strip == "*"

      !existing.nil? && header.split(",").map(&:strip).include?(existing.etag)
    end

    # A 207 body. The trailing DAV:sync-token is RFC 6578 section 3.2's
    # — a sync-collection response MUST carry one naming the state the
    # answer reaches; no other multistatus here has a state to name.
    #: (Array[String] responses, ?sync_token: String) -> String
    def multistatus(responses, sync_token: nil)
      trailing = sync_token ? "  <d:sync-token>#{sync_token}</d:sync-token>\n" : ""
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
          #{responses.join}#{trailing}
        </d:multistatus>
      XML
    end

    #: (String id) -> String
    def contact_href(id)
      "/dav/addressbook/#{id}.vcf"
    end

    # DAV:getetag (RFC 4918 section 15.6).
    #: (Contact contact) -> String
    def etag_response(contact)
      <<~XML
        <d:response>
          <d:href>#{contact_href(contact.id)}</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{contact.etag}</d:getetag>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      XML
    end

    #: (Contact contact) -> String
    def card_response(contact)
      <<~XML
        <d:response>
          <d:href>#{contact_href(contact.id)}</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{contact.etag}</d:getetag>
              <card:address-data>#{xml_escape(contact.vcard.to_s.chomp)}</card:address-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      XML
    end

    # A member the collection does not answer for: the multiget miss,
    # reported as a 404 inside the 207 rather than failing the request
    # (RFC 6352 section 8.7), and the removal shape a sync-collection
    # delta reports (RFC 6578 section 3.2 — href and 404, no propstat).
    #: (String requested) -> String
    def missing_response(requested)
      <<~XML
        <d:response>
          <d:href>#{xml_escape(requested)}</d:href>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:response>
      XML
    end

    # Text nodes in XML built by interpolation; hrefs and vCard content
    # can all contain &, <, or >.
    #: (String text) -> String
    def xml_escape(text)
      text.gsub(/[&<>]/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
    end
  end
end
