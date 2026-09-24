require "pro_tacts"

module ProTacts
  # Who is asking: the login on Remote-User, which the proxy in front
  # of this app writes, and which is trustworthy only behind such a
  # proxy — reached directly the app trusts whatever it is handed, so
  # it must not be listening anywhere but localhost
  # (docs/plans/2026-09-15-identity-from-one-header.md, "Which
  # header").
  #
  # A request that names nobody raises rather than passing a nil
  # down (Web's error handler maps the raise to the 401). That
  # covers the two cases Tailscale documents as having no identity:
  # Funnel traffic, which is public, and traffic from tagged devices.
  # A family device that gets tagged will start seeing 401s.
  #
  # Any login the proxy vouches for is accepted. Getting onto the tailnet
  # is the access control; the login only picks which address book a
  # client syncs (docs/plans/2026-09-12-per-user-books.md).
  #
  # The value arrives as written. Caddy copies a placeholder through
  # verbatim, and a tailnet login is an email address, so there is no
  # header encoding to undo — `tailscale serve` would MIME-encode a
  # non-ASCII value (it Q-encodes what it writes), but nothing in front
  # of this app is serve.
  module ProxyAuth
    # The header the proxy writes the login to, and Rack's spelling of
    # the same field in the environment. One pair, because three places
    # name it: the read below, the 401 that says which header was read
    # (Web#unauthorized), and the Sentry scrubber that keeps it out of
    # an event (config.ru).
    HEADER = "Remote-User" #: String
    ENV_KEY = "HTTP_#{HEADER.upcase.tr("-", "_")}" #: String

    # What #login raises for a request that names nobody. Its own
    # class, so Web's error handler can answer exactly it with the
    # 401 and nothing wider is ever caught — an unexpected failure
    # still propagates to Sentry (see web.rb).
    class MissingLogin < StandardError
    end

    # The login on a request. Read as UTF-8, which is the encoding a
    # login reaches the store in (AGENTS.md's note on STRICT
    # columns); bytes that are not text at all name nobody rather
    # than raising at the bind, several layers down, on a group
    # named after them.
    #: (Rack::env env) -> String
    def self.login(env)
      login = env[ENV_KEY].to_s.dup.force_encoding(Encoding::UTF_8)
      # Checked before strip, which raises on invalid bytes.
      raise MissingLogin, "the #{HEADER} header is not valid UTF-8" unless login.valid_encoding?

      login = login.strip
      raise MissingLogin, "no login on the #{HEADER} header" if login.empty?

      login
    end
  end
end
