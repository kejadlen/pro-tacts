
require "pro_tacts"
require "sentry-ruby"

require "rack/rewindable_input"
require "nokogiri"
require "roda"

require "pro_tacts/debug_logger"
require "pro_tacts/addressbook"
require "roda/plugins/dav_verbs"

module ProTacts
  class Web < Roda
    # RewindableInput allows us to read the request body for Sentry logging
    # and then rewind it so the application can still access it.
    use Rack::RewindableInput::Middleware
    use Sentry::Rack::CaptureExceptions
    if ProTacts.config.debug?
      logger = ProTacts::DebugLogger.open_log(ProTacts.config.debug_log_path)
      use ProTacts::DebugLogger, logger: logger
    end

    plugin :all_verbs
    plugin :dav_verbs

    plugin :not_found do
      Sentry.capture_message("404 Not Found", level: :warning)
      "Not Found"
    end

    route do |r|
      r.is "" do
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

        r.get do
          r.redirect "/dav/principal/", 301
        end
      end

      r.on "dav" do
        r.options do
          response["DAV"] = "addressbook"
          response["Allow"] = "OPTIONS, PROPFIND, REPORT"
          ""
        end

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

            depth = request.env.fetch("HTTP_DEPTH", "infinity")

            # Check if this is an etag-only request (Depth:1 listing)
            etag_only = body.include?("getetag") && !body.include?("displayname") && !body.include?("resourcetype")

            # Etag-only asks want the members; the collection self-entry
            # is omitted until a client is found to need it. Full property
            # requests (Depth:0 collection info) get the collection entry.
            collection_response = ""
            unless etag_only
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
                      <cs:getctag>#{addressbook.ctag}</cs:getctag>
                      <d:sync-token>#{addressbook.sync_token}</d:sync-token>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              XML
            end

            # Depth: 0 returns only collection, Depth: 1 includes members
            members = depth == "0" ? "" : addressbook.contacts.map { etag_response(it) }.join

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

            if doc.root.name == "sync-collection"
              # The warm-sync ask is etag-only; a changed etag sends the
              # client back through multiget, so no address-data here.
              responses = addressbook.contacts.map { etag_response(it) }
            else
              wants_cards = doc.xpath("//address-data").any?

              responses = doc.xpath("//href").map { it.text }.map { |requested|
                id = requested[%r{\A/dav/addressbook/([^/]+)\.vcf\z}, 1]
                contact = id && addressbook.contacts.find { it.id == id }

                if contact
                  wants_cards ? card_response(contact) : etag_response(contact)
                else
                  missing_response(requested)
                end
              }
            end

            <<~XML
              <?xml version="1.0" encoding="UTF-8"?>
              <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
                #{responses.join}
              </d:multistatus>
            XML
          end

          r.get String do |filename|
            contact = addressbook.contacts.find { it.id == filename.delete_suffix(".vcf") }

            # No match falls through to the empty-body 404 that the
            # not_found handler fills in.
            if contact
              response["Content-Type"] = "text/vcard; charset=utf-8"
              response["ETag"] = contact.etag
              contact.vcard
            end
          end
        end
      end
    end

    private

    # Loaded once per request — Roda builds a fresh app instance for each
    # one — with the directory coming from config. Real etags and ctags
    # make an mtime-keyed cache possible, but re-parsing a family address
    # book per request is cheap and can never serve a stale change tag.
    def addressbook
      @addressbook ||= Addressbook.load(ProTacts.config.contacts_dir)
    end

    def contact_href(id)
      "/dav/addressbook/#{id}.vcf"
    end

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
    def xml_escape(text)
      text.gsub(/[&<>]/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
    end
  end
end
