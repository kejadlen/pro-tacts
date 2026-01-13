# frozen_string_literal: true

require "sentry-ruby"

Sentry.init do |config|
  # TODO: Consolidate configuration
  config.dsn = ENV.fetch("SENTRY_DSN")

  # Get breadcrumbs from logs
  config.breadcrumbs_logger = [:sentry_logger, :http_logger]

  # Add data like request headers and IP for users, if applicable;
  # see https://docs.sentry.io/platforms/ruby/data-management/data-collected/ for more info
  config.send_default_pii = true

  # Trace all the things!
  config.traces_sample_rate = 1.0
end

require "rack/rewindable_input"
require "roda"

require "roda/plugins/dav_verbs"

module ProTacts
  class Web < Roda
    # RewindableInput allows us to read the request body for Sentry logging
    # and then rewind it so the application can still access it.
    use Rack::RewindableInput::Middleware
    use Sentry::Rack::CaptureExceptions

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

      r.get ".well-known/carddav" do
        r.redirect "/dav/principal/", 301
      end

      r.on "dav" do
        r.options do
          response["DAV"] = "1, 3, addressbook"
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
            response["Content-Type"] = "text/xml"
            response.status = 207

            <<~XML
              <?xml version="1.0" encoding="UTF-8"?>
              <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
                <d:response>
                  <d:href>/dav/addressbook/test-contact.vcf</d:href>
                  <d:propstat>
                    <d:prop>
                      <d:getetag>"etag-123"</d:getetag>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              </d:multistatus>
            XML
          end

          r.get String do |uid|
            response["Content-Type"] = "text/vcard"

            <<~VCARD
              BEGIN:VCARD
              VERSION:3.0
              FN:Test Contact
              N:Contact;Test;;;
              END:VCARD
            VCARD
          end
        end
      end
    end
  end
end
