# frozen_string_literal: true

require "roda"
require "sentry-ruby"

require "roda/plugins/dav_verbs"

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

module ProTacts
  class Web < Roda
    plugin :all_verbs
    plugin :dav_verbs

    plugin :not_found do
      Sentry.capture_message("404 Not Found", level: :warning, extra: {
        path: request.path,
        method: request.request_method
      })
      "Not Found"
    end

    route do |r|
      r.options do
        response["DAV"] = "1, 3, addressbook"
        response["Allow"] = "OPTIONS, PROPFIND, REPORT"
        ""
      end

      r.get ".well-known/carddav" do
        r.redirect "/principal/", 301
      end

      r.on "principal" do
        r.propfind do
          response["Content-Type"] = "text/xml"
          response.status = 207

          <<~XML
            <?xml version="1.0" encoding="UTF-8"?>
            <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
              <d:response>
                <d:href>/principal/</d:href>
                <d:propstat>
                  <d:prop>
                    <card:addressbook-home-set>
                      <d:href>/addressbook/</d:href>
                    </card:addressbook-home-set>
                  </d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
          XML
        end
      end
    end
  end
end
