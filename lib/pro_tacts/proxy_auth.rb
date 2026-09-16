require "pro_tacts"

module ProTacts
  # Who is asking: the login on Remote-User, which the proxy in front of
  # this app writes (docs/plans/2026-09-15-identity-from-one-header.md).
  #
  # The Caddy site's `header_up` sets Remote-User, overwriting whatever
  # arrived, so a client cannot supply its own. That makes the header
  # trustworthy, but only behind such a proxy: reached directly, the app
  # trusts whatever it is handed. The app must not be listening anywhere
  # but localhost.
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

    # Remote-User as Rack spells it in the environment.
    ENV_KEY = "HTTP_REMOTE_USER" #: String

    # The login on a request, or nil for one that names nobody.
    #: (Rack::env env) -> String?
    def self.login(env)
      login = decode(env[ENV_KEY].to_s)&.strip
      login unless login.nil? || login.empty?
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
