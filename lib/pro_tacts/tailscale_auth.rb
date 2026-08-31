module ProTacts
  # Gates every request on the identity headers Tailscale serve injects.
  #
  # Serve sets Tailscale-User-Login from the tailnet identity of the calling
  # node, and strips the header from incoming requests before proxying so a
  # client cannot supply its own. That makes the header trustworthy, but only
  # behind serve: reached directly, this middleware trusts whatever it is
  # handed. The app must not be listening anywhere but localhost.
  #
  # Failing closed covers the two cases Tailscale documents as having no
  # identity: Funnel traffic, which is public, and traffic from tagged
  # devices. A family device that gets tagged will start seeing 403s.
  #
  # Any tailnet identity is accepted. Getting onto the tailnet is the access
  # control; the address book has no per-user view to protect.
  class TailscaleAuth
    # @rbs @app: Rack::_App

    LOGIN_HEADER = "HTTP_TAILSCALE_USER_LOGIN"
    NAME_HEADER = "HTTP_TAILSCALE_USER_NAME"

    # Where the authenticated login lands for anything downstream that wants
    # to know who is asking.
    IDENTITY = "pro_tacts.user"

    #: (Rack::_App app) -> void
    def initialize(app)
      @app = app
    end

    #: (Rack::env env) -> Rack::response
    def call(env)
      login = env[LOGIN_HEADER].to_s.strip

      # 403 rather than 401: no credentials the client could supply would
      # help, so there is no challenge worth sending.
      return forbidden if login.empty?

      env[IDENTITY] = login
      @app.call(env)
    end

    private

    #: () -> Rack::response
    def forbidden
      body = "Forbidden: no Tailscale identity on this request.\n"
      # Lowercase names: a bare Rack 3 response hash is not normalized
      # on the way out the way Roda's response[ ]= is, and rackup's
      # development Lint rejects an uppercase name with a 500 that hides
      # the 403.
      [403, { "content-type" => "text/plain", "content-length" => body.bytesize.to_s }, [body]]
    end
  end
end
