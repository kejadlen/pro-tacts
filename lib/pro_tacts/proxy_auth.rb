require "pro_tacts"

module ProTacts
  # Who is asking: the login on the one request header the proxy in front
  # of this app writes it to, named by ProTacts.config.identity_header
  # (docs/plans/2026-09-15-identity-from-one-header.md).
  #
  # `tailscale serve` writes Tailscale-User-Login from the tailnet
  # identity of the calling node and strips it from incoming requests
  # before proxying, and a Caddy site's `header_up` sets the header it
  # names, overwriting whatever arrived. Either way a client cannot
  # supply its own. That makes the header trustworthy, but only behind
  # such a proxy: reached directly, the app trusts whatever it is
  # handed. The app must not be listening anywhere but localhost.
  #
  # A request that names nobody is refused at the top of Web's route
  # (Web#unauthorized). That covers the two cases Tailscale documents as
  # having no identity: Funnel traffic, which is public, and traffic from
  # tagged devices. A family device that gets tagged will start seeing
  # 401s.
  #
  # Any login the proxy vouches for is accepted. Getting onto the tailnet
  # is the access control; the login only picks which address book a
  # client syncs (docs/plans/2026-09-12-per-user-books.md).
  module ProxyAuth
    # One RFC 2047 encoded-word (section 2), and the whitespace after it
    # when another follows: section 6.2 has that whitespace dropped, so a
    # long value split across words decodes whole.
    ENCODED_WORD = /=\?([^?\s]+)\?([QqBb])\?([^?\s]+)\?=/ #: Regexp
    ENCODED_RUN = /#{ENCODED_WORD}(?:[ \t]+(?=#{ENCODED_WORD}))?/ #: Regexp
    private_constant :ENCODED_WORD, :ENCODED_RUN

    # The login on a request, or nil for one that names nobody. The
    # header is an argument so a caller can read one this deployment is
    # not configured for; every caller in the app takes the default.
    #: (Rack::env env, ?header: String) -> String?
    def self.login(env, header: ProTacts.config.identity_header)
      login = decode(env[env_key(header)].to_s)&.strip
      login unless login.nil? || login.empty?
    end

    # Rack's spelling of a request header (the Rack SPEC's environment):
    # upcased, dashes to underscores, HTTP_ in front.
    #: (String header) -> String
    def self.env_key(header)
      "HTTP_#{header.upcase.tr("-", "_")}"
    end

    # A header value as serve writes it: Go's mime.QEncoding over the
    # UTF-8 value (encTailscaleHeaderValue in tailscale's
    # ipn/ipnlocal/serve.go), which leaves an ASCII value as it is. Nil
    # for anything that does not decode to UTF-8 — a charset other than
    # UTF-8 included, since serve never writes one.
    #: (String value) -> String?
    def self.decode(value)
      decoded = value.dup.force_encoding(Encoding::UTF_8).gsub(ENCODED_RUN) {
        charset, encoding, text = $1.to_s, $2.to_s, $3.to_s
        return nil unless charset.casecmp?("utf-8")

        decode_word(encoding, text) or return nil
      }
      decoded if decoded.valid_encoding?
    end

    # Q is section 4.2, whose underscore is a space whatever else the
    # text holds; B is section 4.1's base64, strict so a malformed word
    # is refused rather than read as whatever part of it decodes.
    #: (String encoding, String text) -> String?
    def self.decode_word(encoding, text)
      bytes =
        if encoding.casecmp?("q")
          text.tr("_", " ").unpack1("M")
        else
          text.unpack1("m0")
        end #: String
      bytes.force_encoding(Encoding::UTF_8)
    rescue ArgumentError
      # unpack1("m0")'s refusal of text that is not base64.
      nil
    end
    private_class_method :decode_word
  end
end
