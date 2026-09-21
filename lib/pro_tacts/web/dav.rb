require "digest"
require "nokogiri"

require "pro_tacts/dav_xml"

module ProTacts
  # The CardDAV half of the router: service discovery and the one
  # address book each user syncs (docs/plans/2026-09-12-per-user-books.md).
  # Four specs meet here: WebDAV itself (RFC 4918), the CardDAV profile
  # on top of it (RFC 6352), collection sync (RFC 6578), and service
  # discovery (RFC 6764). Each handler cites its section, and the texts
  # are vendored under docs/rfcs to check them against.
  class Web < Roda
    # The "carddav" well-known URI (RFC 6764 section 5, registered in
    # section 9.1.2), the start of a client's bootstrap.
    hash_branch(".well-known") do |r|
      r.on "carddav" do
        r.propfind do
          current_user_principal("/.well-known/carddav")
        end

        # RFC 6764 section 5 forbids putting the service itself here and
        # requires a redirect to the real context path; 301 is one of the
        # codes it names.
        r.get do
          r.redirect "/dav/principal/", 301
        end
      end
    end

    hash_branch("dav") do |r|
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

          multistatus("card") do |d, card|
            d.found("/dav/principal/") do
              card.addressbook_home_set do
                d.href "/dav/addressbook/"
              end
            end
          end
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

          multistatus("card", "cs") do |d, card, cs|
            # The collection self-entry is omitted from an etag-only ask
            # until a client is found to need it.
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
              # all — the PUT they prompted is what the exchange log
              # captured them for. DAV:write covers PUT and PROPPATCH
              # (RFC 3744 section 3.2), and PUT is the one of the pair
              # answered; DAV:unbind is removing a member from the
              # collection (section 3.10), which DELETE answers.
              # DAV:bind is adding one (section 3.9), and the create it
              # names — POST to the collection with DAV:add-member — has
              # no route: PUT to the member URI is how both clients
              # create, so nothing has asked for it.
              d.found("/dav/addressbook/") do
                d.resourcetype do
                  d.collection
                  card.addressbook
                end
                d.supported_report_set do
                  d.supported_report do
                    d.report do
                      d.sync_collection
                    end
                  end
                end
                cs.getctag ctag
                d.sync_token sync_token
                d.current_user_privilege_set do
                  d.privilege do
                    d.read
                  end
                  d.privilege do
                    d.write
                  end
                  d.privilege do
                    d.bind
                  end
                  d.privilege do
                    d.unbind
                  end
                end
              end
            end

            unless depth == "0"
              contacts.each do
                etag_response(d, it)
              end
            end
          end
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
            # The token carries the change log's sequence and whose book
            # it was issued for (see #sync_token), and the delta is the
            # log after the sequence, answered from the requester's book
            # as it is now: a card that left it answers as removed
            # (section 3.5.2), and so does one that never was in it,
            # which the log cannot tell apart. One response per
            # member, the net of everything it did in the
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
              multistatus("card", sync_token:) do |d|
                contacts.each do
                  etag_response(d, it)
                end
              end
            elsif (sequence = token[%r{\Ahttp://pro-tacts/sync/(\d+)/#{book_digest}\z}, 1]) &&
                sequence.to_i <= store.latest_sequence
              net = store.changes(after: sequence.to_i).map { it.card_id }.uniq
              multistatus("card", sync_token:) do |d|
                net.each do |id|
                  contact = contacts.find { it.id == id }
                  contact ? etag_response(d, contact) : d.missing(contact_href(id))
                end
              end
            else
              # A token this server never issued, one issued for another
              # book, or one naming a state past the present: the
              # section's DAV:valid-sync-token
              # precondition, marshalled per RFC 4918 section 16. 410
              # rather than 403 because its fallback is a full resync —
              # the request will not always fail, and the state the
              # token names is gone.
              response.status = 410

              DavXml.document("error") do |d|
                d.valid_sync_token
              end
            end
          when "addressbook-multiget"
            # CARDDAV:addressbook-multiget (RFC 6352 section 8.7); the
            # address-data the client asks for is section 10.4.
            wants_cards = doc.xpath("//address-data").any?

            multistatus("card") do |d, card|
              doc.xpath("//href").map { it.text }.each do |requested|
                id = requested[%r{\A/dav/addressbook/([^/]+)\.vcf\z}, 1]
                contact = id && contacts.find { it.id == id }

                if contact
                  wants_cards ? card_response(d, card, contact) : etag_response(d, contact)
                else
                  d.missing(requested)
                end
              end
            end
          else
            # The DAV:supported-report precondition on REPORT (RFC 3253
            # section 3.6) — the report asked for has to be one the
            # resource supports. Answering an unsupported report with an
            # empty 207 reads to the client as a successful empty result,
            # and to us as nothing at all: 207 is not a status the
            # exchange log keeps, so the one signal that a client wanted
            # something unimplemented never fired.
            #
            # 403 with the precondition named in a DAV:error body is the
            # marshalling RFC 4918 section 16 defines, and 403 is its
            # "will always fail, do not repeat" case. addressbook-query
            # (RFC 6352 section 8.6) is the report this rejects today;
            # macOS Contacts has never sent one.
            response.status = 403

            DavXml.document("error") do |d|
              d.supported_report
            end
          end
        end

        # Read on its own rather than through the collection: serving
        # one href has no reason to load every other contact first.
        r.get String do |filename|
          contact = member(filename.delete_suffix(".vcf"))

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
        # docs/apple-contacts.md, "What a write looks like on the wire".
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

    private

    # DAV:current-user-principal (RFC 5397 section 3) — what a client
    # asks the root and the well-known URI for to find the principal it
    # is acting as.
    #: (String href) -> String
    def current_user_principal(href)
      response["Content-Type"] = "text/xml"
      response.status = 207

      multistatus do |d|
        d.found(href) do
          d.current_user_principal do
            d.href "/dav/principal/"
          end
        end
      end
    end

    # Read once per request — Roda builds a fresh app instance for each
    # one — from the store the whole process shares. Reading a family
    # address book per request is cheap and can never serve a stale one.
    #
    # The requester's book and nothing else: every route under /dav serves
    # that collection (docs/plans/2026-09-12-per-user-books.md).
    #: () -> Array[Contact]
    def contacts
      @contacts ||= store.contacts.select { book.include?(it.id) }
    end

    #: () -> Set[String]
    def book
      @book ||= store.book_cards(@login)
    end

    # One member of the requester's book, or nil for a card outside it
    # as for one that does not exist: neither is a member of this
    # collection.
    #: (String id) -> Contact?
    def member(id)
      store.contact(id) if book.include?(id)
    end

    #: () -> String
    def ctag
      @ctag ||= store.ctag
    end

    # Sync tokens are opaque to the client (RFC 6578 section 3); the URI
    # form is conventional. Built on the ctag so a client polling either
    # one sees changes at the same points, and on the requester's login
    # so that a token is refused by any other book, the one a rename
    # leaves a user with included (docs/plans/2026-09-12-per-user-books.md,
    # "The wire").
    #: () -> String
    def sync_token
      "http://pro-tacts/sync/#{ctag}/#{book_digest}"
    end

    # The name half of a sync token: the first 16 hex digits of the
    # SHA-256 of the requester's login.
    #: () -> String
    def book_digest
      Digest::SHA256.hexdigest(@login)[0, 16].to_s
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
      # A card outside the requester's book is no member of this
      # collection (#member), and its id cannot be created here either,
      # being taken: the 404 the GET of it gets.
      return if !book.include?(id) && store.contact(id)

      # CARDDAV:supported-address-data (RFC 6352 section 6.3.2.1): what
      # arrived must be a vCard, and text/vcard is the one media type
      # this server stores. Asked before the body is read because it is
      # a question about the request, not about what the request
      # carried.
      return precondition(:supported_address_data) unless request.media_type == "text/vcard"

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
      bytes = request.body.read.force_encoding(Encoding::UTF_8)
      return precondition(:valid_address_data) unless bytes.valid_encoding?

      # CARDDAV:valid-address-data again, on the card this time: the
      # envelope RFC 2426 section 4 requires. That is the whole test. A
      # line inside it this parser cannot read is not grounds for
      # refusing the card: RFC 6352 section 6.3.2.2 has the server keep
      # what it does not understand, and it is kept — the stored bytes
      # are what goes back out.
      vcard = VCard.new(bytes)
      return precondition(:valid_address_data) unless vcard.card?

      # CARDDAV:no-uid-conflict: the submitted UID must not belong to a
      # different resource, and a mapped URI must not be overwritten by
      # a card carrying a different UID. Here the id is the card's UID
      # (see Contact), so both clauses come down to: the card carries a
      # UID naming the resource being written, and no other card claims
      # it. The href in the body is the SHOULD that section attaches to
      # the first clause — report where the UID already lives.
      uid = vcard.uid
      owner = uid && store.card_id_with_uid(uid)
      return precondition(:no_uid_conflict, owner) if uid != id || owner && owner != id

      existing = store.contact(id)

      # The lost-update conditionals, RFC 7232 sections 3.1 and 3.2.
      # macOS sends If-Match on updates and If-None-Match: * on creates;
      # a PUT carrying neither is unconditional and allowed to proceed.
      if_match = request.env["HTTP_IF_MATCH"]
      return plain_412 if if_match && !if_match_satisfied?(if_match, existing)

      if_none_match = request.env["HTTP_IF_NONE_MATCH"]
      return plain_412 if if_none_match && if_none_match_failed?(if_none_match, existing)

      report_unreadable_lines(vcard)
      report_broken_assumptions(vcard)

      stored = store.put(id, vcard, client: true)
      response.status = existing ? 204 : 201
      # A strong ETag belongs on the answer only when what the resource
      # now serves is the submitted bytes, octet for octet — the one
      # case RFC 6352 section 6.3.2.3 lets a client rely on the tag it
      # gets back, and anywhere else it forbids one outright. Which is
      # the composed card against the body, not the stored one: a
      # birthday and a group's lines are both subtracted before storage
      # and composed back in on read, so a member returning the card it
      # downloaded stores fewer bytes than it sent and still gets the
      # tag, while a PUT that carried a birthday somewhere other than
      # where compose puts it back serves bytes that are not the ones
      # it sent, and the client refetches.
      response["ETag"] = stored.etag if stored.vcard.to_s == vcard.to_s

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
      # not_found handler the way the GET and PUT of a bad id do. A card
      # outside the requester's book is unmapped here too (#member).
      existing = member(id)
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
      # removed member as href plus 404 (DavXml::DAV#missing).
      store.delete(id)
      response.status = 204

      # Bodyless for the 204, write_card's reason.
      nil
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
    # carries no card content (the line config.ru draws for Sentry); the
    # admin view shows the card raw.
    #: (VCard vcard) -> void
    def report_broken_assumptions(vcard)
      broken = vcard.lines.count { it.broke_assumption? }
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
    #: (VCard vcard) -> void
    def report_unreadable_lines(vcard)
      unreadable = vcard.lines.count { it.unreadable? }
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
    #: (:supported_address_data | :valid_address_data | :no_uid_conflict element, ?String? conflict_id) -> String
    def precondition(element, conflict_id = nil)
      response.status = 412

      DavXml.document("error", "card") do |d, card|
        card.public_send(element) do
          d.href contact_href(conflict_id) if conflict_id
        end
      end
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
    #: (*String prefixes, ?sync_token: String?) { (DavXml::DAV d, DavXml::CardDAV card, DavXml::CalendarServer cs) -> void } -> String
    def multistatus(*prefixes, sync_token: nil)
      DavXml.document("multistatus", *prefixes) do |d, card, cs|
        yield d, card, cs
        d.sync_token sync_token if sync_token
      end
    end

    #: (String id) -> String
    def contact_href(id)
      "/dav/addressbook/#{id}.vcf"
    end

    # DAV:getetag (RFC 4918 section 15.6).
    #: (DavXml::DAV d, Contact contact) -> void
    def etag_response(d, contact)
      d.found(contact_href(contact.id)) do
        d.getetag contact.etag
      end
    end

    #: (DavXml::DAV d, DavXml::CardDAV card, Contact contact) -> void
    def card_response(d, card, contact)
      d.found(contact_href(contact.id)) do
        d.getetag contact.etag
        card.address_data contact.vcard.to_s.chomp
      end
    end
  end
end
