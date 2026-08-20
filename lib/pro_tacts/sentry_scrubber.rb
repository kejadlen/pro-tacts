module ProTacts
  # Redacts card content from request bodies on their way to Sentry.
  #
  # Everything else in a request is fine to send: hrefs carry opaque contact
  # UIDs, and the IPs are tailnet addresses. Card content is the exception,
  # and a write path would put it straight in a PUT body.
  #
  # Sentry truncates bodies at 16KB (RequestInterface::MAX_BODY_LIMIT), so a
  # card can arrive with its BEGIN and no END. The trailing alternation
  # handles that, and is load-bearing for the ordinary case too: (?~) is
  # greedy up to the longest run with no complete END:VCARD in it, which
  # runs into the marker and stops at END:VCAR. Requiring END:VCARD or the
  # end of the body is what backtracks it onto the real boundary.
  module SentryScrubber
    VCARD = /BEGIN:VCARD(?~END:VCARD)(?:END:VCARD|\z)/mi
    VCARD_CONTENT_TYPE = %r{\Atext/vcard}i
    REDACTED = "[vcard redacted]".freeze #: String

    # Sentry discards the event unless a Sentry::ErrorEvent comes back, so
    # this returns the event it was handed either way.
    #: (untyped event, ?untyped hint) -> untyped
    def self.call(event, _hint = nil)
      request = event.request if event.respond_to?(:request)
      return event unless request

      request.data =
        if vcard_body?(request)
          REDACTED
        else
          redact(request.data)
        end

      event
    end

    # A card PUT is a card whether or not it parses, so the content type is
    # enough on its own.
    #: (untyped request) -> bool
    def self.vcard_body?(request)
      headers = request.headers
      return false unless headers.respond_to?(:[])

      headers["Content-Type"].to_s.match?(VCARD_CONTENT_TYPE)
    end

    # Form bodies arrive as a params hash rather than a string.
    #: (untyped data) -> untyped
    def self.redact(data)
      case data
      when String then data.gsub(VCARD, REDACTED)
      when Hash then data.transform_values { redact(it) }
      when Array then data.map { redact(it) }
      else data
      end
    end
  end
end
