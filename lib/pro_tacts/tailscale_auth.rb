module ProTacts
  # Who is asking, read off the identity headers Tailscale serve injects.
  #
  # Serve sets Tailscale-User-Login and Tailscale-User-Name from the
  # tailnet identity of the calling node, and strips both from incoming
  # requests before proxying so a client cannot supply its own. That makes
  # the headers trustworthy, but only behind serve: reached directly, the
  # app trusts whatever it is handed. The app must not be listening
  # anywhere but localhost.
  #
  # A request that names nobody is refused at the top of Web's route
  # (Web#unauthorized). That covers the two cases Tailscale documents as
  # having no identity: Funnel traffic, which is public, and traffic from
  # tagged devices. A family device that gets tagged will start seeing
  # 401s.
  #
  # Any tailnet identity is accepted. Getting onto the tailnet is the access
  # control; the name only picks which address book a client syncs
  # (docs/plans/2026-09-12-per-user-books.md).
  module TailscaleAuth
    LOGIN_HEADER = "HTTP_TAILSCALE_USER_LOGIN"
    NAME_HEADER = "HTTP_TAILSCALE_USER_NAME"

    # Who is asking, both headers decoded. The signature is in
    # sig/pro_tacts/tailscale_auth.rbs.
    # @rbs skip
    Identity = Data.define(:login, :name)

    # One RFC 2047 encoded-word (section 2), and the whitespace after it
    # when another follows: section 6.2 has that whitespace dropped, so a
    # long value split across words decodes whole.
    ENCODED_WORD = /=\?([^?\s]+)\?([QqBb])\?([^?\s]+)\?=/ #: Regexp
    ENCODED_RUN = /#{ENCODED_WORD}(?:[ \t]+(?=#{ENCODED_WORD}))?/ #: Regexp
    private_constant :ENCODED_WORD, :ENCODED_RUN

    # The identity on a request, or nil for one that names nobody.
    #: (Rack::env env) -> Identity?
    def self.identity(env)
      login = decode(env[LOGIN_HEADER].to_s)&.strip
      name = decode(env[NAME_HEADER].to_s)&.strip
      return if login.nil? || login.empty? || name.nil? || name.empty?

      Identity.new(login:, name:)
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
