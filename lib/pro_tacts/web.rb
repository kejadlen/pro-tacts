# frozen_string_literal: true

require "pro_tacts"
require "sentry-ruby"

# Tests skip Sentry entirely: capture_message and the rack middleware are
# no-ops while Sentry is uninitialized, so no DSN is needed there.
unless ProTacts.config.test?
  Sentry.init do |sentry|
    sentry.dsn = ProTacts.config.sentry_dsn

    # Get breadcrumbs from logs
    sentry.breadcrumbs_logger = [:sentry_logger, :http_logger]

    # Add data like request headers and IP for users, if applicable;
    # see https://docs.sentry.io/platforms/ruby/data-management/data-collected/ for more info
    sentry.send_default_pii = true

    # Trace all the things!
    sentry.traces_sample_rate = 1.0
  end
end

require "rack/rewindable_input"
require "roda"

require "pro_tacts/debug_logger"
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
    plugin :common_logger

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
                    <d:principal-URL>
                      <d:href>/dav/principal/</d:href>
                    </d:principal-URL>
                    <d:resourcetype>
                      <d:collection/>
                    </d:resourcetype>
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
                    <d:principal-URL>
                      <d:href>/dav/principal/</d:href>
                    </d:principal-URL>
                    <d:resourcetype>
                      <d:collection/>
                    </d:resourcetype>
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
          response["DAV"] = "1, 3, access-control, addressbook"
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
                      <d:displayname>Default Principal</d:displayname>
                      <d:principal-URL>
                        <d:href>/dav/principal/</d:href>
                      </d:principal-URL>
                      <d:resourcetype>
                        <d:principal/>
                      </d:resourcetype>
                      <card:addressbook-home-set>
                        <d:href>/dav/addressbook/</d:href>
                      </card:addressbook-home-set>
                      <d:supported-report-set>
                        <d:supported-report>
                          <d:report><card:addressbook-multiget/></d:report>
                        </d:supported-report>
                        <d:supported-report>
                          <d:report><card:addressbook-query/></d:report>
                        </d:supported-report>
                      </d:supported-report-set>
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

            contact_etag = %("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
            collection_ctag = "ctag-1"
            depth = request.env["HTTP_DEPTH"] || "infinity"

            # Check if this is an etag-only request (Depth:1 listing)
            etag_only = body.include?("getetag") && !body.include?("displayname") && !body.include?("resourcetype")

            if etag_only
              # Simple etag listing for sync
              collection_response = <<~XML
                <d:response>
                  <d:href>/dav/addressbook/</d:href>
                  <d:propstat>
                    <d:prop>
                      <d:getetag>"#{collection_ctag}"</d:getetag>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              XML

              contact_response = <<~XML
                <d:response>
                  <d:href>/dav/addressbook/AB12C345-6789-0DEF-1234-567890ABCDEF.vcf</d:href>
                  <d:propstat>
                    <d:prop>
                      <d:getetag>#{contact_etag}</d:getetag>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              XML
            else
              # Full property request (Depth:0 collection info)
              collection_response = <<~XML
                <d:response>
                  <d:href>/dav/addressbook/</d:href>
                  <d:propstat>
                    <d:prop>
                      <d:resourcetype>
                        <d:collection/>
                        <card:addressbook/>
                      </d:resourcetype>
                      <cs:getctag>#{collection_ctag}</cs:getctag>
                      <d:sync-token>http://pro-tacts/sync/1</d:sync-token>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              XML

              contact_response = <<~XML
                <d:response>
                  <d:href>/dav/addressbook/AB12C345-6789-0DEF-1234-567890ABCDEF.vcf</d:href>
                  <d:propstat>
                    <d:prop>
                      <d:getetag>#{contact_etag}</d:getetag>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              XML
            end

            # Depth: 0 returns only collection, Depth: 1 includes members
            members = depth == "0" ? "" : contact_response

            <<~XML
              <?xml version="1.0" encoding="UTF-8"?>
              <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/">
                #{collection_response}
                #{members}
              </d:multistatus>
            XML
          end

          r.report do
            response["Content-Type"] = "text/xml"
            response.status = 207
            contact_etag = %("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
            vcard = <<~VCARD.chomp
              BEGIN:VCARD
              VERSION:3.0
              PRODID:-//Apple Inc.//macOS 14.6.1//EN
              N:Contact;Test;;;
              FN:Test Contact
              REV:2026-01-14T00:00:00Z
              UID:AB12C345-6789-0DEF-1234-567890ABCDEF
              END:VCARD
            VCARD

            <<~XML
              <?xml version="1.0" encoding="UTF-8"?>
              <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
                <d:response>
                  <d:href>/dav/addressbook/AB12C345-6789-0DEF-1234-567890ABCDEF.vcf</d:href>
                  <d:propstat>
                    <d:prop>
                      <d:getetag>#{contact_etag}</d:getetag>
                      <card:address-data>#{vcard}</card:address-data>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              </d:multistatus>
            XML
          end

          r.get String do |uid|
            response["Content-Type"] = "text/vcard; charset=utf-8"
            response["ETag"] = %("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")

            <<~VCARD.gsub(/^ +/, "")
              BEGIN:VCARD
              VERSION:3.0
              PRODID:-//Apple Inc.//macOS 14.6.1//EN
              N:Contact;Test;;;
              FN:Test Contact
              REV:2026-01-14T00:00:00Z
              UID:AB12C345-6789-0DEF-1234-567890ABCDEF
              END:VCARD
            VCARD
          end
        end
      end
    end
  end
end
