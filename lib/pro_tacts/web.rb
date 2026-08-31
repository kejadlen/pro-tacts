
require "pathname"

require "pro_tacts"
require "sentry-ruby"

require "rack/rewindable_input"
require "nokogiri"
require "roda"

require "pro_tacts/admin/contacts_index"
require "pro_tacts/admin/contacts_show"
require "pro_tacts/debug_logger"
require "pro_tacts/contact"
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

      # The read-only admin UI (docs/DESIGN.md). Under the same auth
      # gate as the CardDAV routes above it — "a few family members, all
      # trusted" is the whole access model this app has, see README's
      # simplifying assumptions.
      r.on "admin" do
        r.on "contacts" do
          r.is do
            r.get do
              response["Content-Type"] = "text/html; charset=utf-8"
              Admin::ContactsIndex.call(recent: store.contacts_by_recency, query: r.params["q"])
            end
          end

          r.get String do |id|
            contact = store.contact(id)

            # No match falls through to the empty-body 404 the
            # not_found handler fills in, same as the CardDAV GET.
            if contact
              response["Content-Type"] = "text/html; charset=utf-8"
              Admin::ContactsShow.call(contact:)
            end
          end
        end
      end

      r.is "" do
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
          response["Allow"] = "OPTIONS, PROPFIND, REPORT, PUT"
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

            # Check if this is an etag-only request (Depth:1 listing)
            etag_only = body.include?("getetag") && !body.include?("displayname") && !body.include?("resourcetype")

            # Etag-only asks want the members; the collection self-entry
            # is omitted until a client is found to need it. Full property
            # requests (Depth:0 collection info) get the collection entry.
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
              # answered; DAV:bind is adding a member to the collection
              # (section 3.9) and DAV:unbind removing one (section 3.10),
              # neither of which has a route yet.
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

            # Depth: 0 returns only collection, Depth: 1 includes members
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
              # DAV:sync-collection (RFC 6578 section 3.2). The warm-sync ask
              # is etag-only; a changed etag sends the client back through
              # multiget, so no address-data here.
              #
              # Knowingly violates that section twice: it requires the
              # multistatus to carry a DAV:sync-token and to report only what
              # changed since the client's token, and this returns every
              # contact with no token. macOS resyncs the whole collection
              # anyway, so it works; a client that trusts the token would
              # break. Fixing it is the incremental-sync work in the backlog.
              multistatus(contacts.map { etag_response(it) })
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

            # No match falls through to the empty-body 404 that the
            # not_found handler fills in.
            if contact
              response["Content-Type"] = "text/vcard; charset=utf-8"
              # RFC 7232 section 2.3; must match the getetag reported for
              # this contact in PROPFIND and REPORT.
              response["ETag"] = contact.etag
              contact.vcard
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
      # The body is the one binary input: Rack requires input in
      # ASCII-8BIT and Rack::RewindableInput enforces it again. Relabel
      # rather than convert — the bytes are untouched, and the charset
      # check below is what judges them. Paths need no counterpart:
      # Puma hands PATH_INFO over still percent-encoded, so an id off
      # the wire is ASCII.
      vcard = request.body.read.force_encoding(Encoding::UTF_8)

      # CARDDAV:supported-address-data (RFC 6352 section 6.3.2.1): what
      # arrived must be a vCard, and text/vcard is the one media type
      # this server stores.
      return precondition("supported-address-data") unless request.media_type == "text/vcard"

      # CARDDAV:valid-address-data: bytes that are the UTF-8 the media
      # type declares, parsing into a card with the envelope RFC 2426
      # section 4 requires. Invalid UTF-8 would otherwise surface as a
      # 500 out of SQLite on the insert, past the point where the
      # client could be told what was wrong with the body.
      return precondition("valid-address-data") unless vcard.valid_encoding?

      properties = parse_card(vcard)
      return precondition("valid-address-data") unless properties && VCard.card?(properties)

      # CARDDAV:no-uid-conflict: the submitted UID must not belong to a
      # different resource, and a mapped URI must not be overwritten by
      # a card carrying a different UID. Here the id is the card's UID
      # (see Contact), so both clauses come down to: the card carries a
      # UID naming the resource being written, and no other card claims
      # it. The href in the body is the SHOULD that section attaches to
      # the first clause — report where the UID already lives.
      uid = VCard.uid(properties)
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
      response["ETag"] = stored.etag if stored.vcard == vcard

      # A returned "" would land in the body and pin text/html and
      # content-length onto the 204, which a bodyless status must not
      # carry (Rack 3's lint rejects both); nil leaves it bodyless.
      nil
    end

    # A parse that answers nil rather than raising when the bytes are
    # not a card — the same tolerance Store#properties_of gives the
    # index, at the point where a caller must decide.
    #: (String vcard) -> Array[VCard::Property]?
    def parse_card(vcard)
      VCard::Parser.parse(vcard)
    rescue VCard::ParseError
      nil
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

    #: (Array[String] responses) -> String
    def multistatus(responses)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
          #{responses.join}
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
              <card:address-data>#{xml_escape(contact.vcard.chomp)}</card:address-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      XML
    end

    # An href with no match is reported as a 404 inside the 207 rather than
    # failing the request (RFC 6352 section 8.7).
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
