require "uri"

module ProTacts
  # Whether a request is a write another site's page made the browser
  # send. The identity is ambient — the proxy writes the login for
  # whichever tailnet device is asking (ProxyAuth), so no cookie is
  # involved and SameSite has nothing to hold back — and a page open on
  # a family member's device can submit a form here, which the browser
  # sends without a preflight and the app would apply as that member.
  # DAV's PUT and DELETE already need a preflight nothing answers, so
  # it is the admin's POSTs this refuses in practice; every method that
  # changes something is asked, so a verb added later is covered too.
  #
  # The browser says where a request came from: Sec-Fetch-Site on every
  # browser that sends it, and Origin on the older ones that do not.
  # A request carrying neither is no browser's — a DAV client, curl —
  # and passes, being nothing a page could have sent.
  module CrossSite
    # The methods that change nothing, and so have nothing to forge.
    READS = %w[GET HEAD OPTIONS PROPFIND REPORT].freeze #: Array[String]

    # Sec-Fetch-Site's answers for a request this site's own page sent,
    # or one a person typed or bookmarked (`none`).
    OWN = %w[same-origin none].freeze #: Array[String]

    #: (Rack::env env) -> bool
    def self.write?(env)
      return false if READS.include?(env["REQUEST_METHOD"])

      site = env["HTTP_SEC_FETCH_SITE"]
      return !OWN.include?(site) unless site.nil?

      origin = env["HTTP_ORIGIN"]
      return false if origin.nil?

      foreign?(origin, env["HTTP_HOST"].to_s)
    end

    # An Origin naming a host other than the one asked, `null` (an
    # opaque origin, a sandboxed frame's) included, whose URI has no
    # host at all. Both are read as URIs so the port falls away from
    # each the same way. One that does not parse is no page of ours
    # either.
    #: (String origin, String host) -> bool
    def self.foreign?(origin, host)
      URI(origin).host != URI("//#{host}").host
    rescue URI::InvalidURIError
      true
    end
  end
end
