require "pro_tacts"
require "pro_tacts/proxy_auth"

module ProTacts
  # Rack middleware that writes a fixed login to Remote-User, the way the
  # proxy in front of a deployment does, so a server with nothing in
  # front answers instead of refusing every request (ProxyAuth, and
  # Web's error handler). A request that already carries the header keeps
  # its own, so `curl -H` can still ask as someone else.
  #
  # It stands in for the proxy, so it belongs only where there is none.
  # Only demo.ru uses it — the dev server and the preview app both — and
  # a deployment runs config.ru, which does not: reached directly the app
  # trusts whatever it is handed, so writing a login in front of real
  # data would hand every anonymous caller that address book.
  class StubLogin
    # @rbs @app: untyped

    LOGIN = "alpha@example.com" #: String

    #: (untyped app) -> void
    def initialize(app)
      @app = app
    end

    #: (Rack::env env) -> untyped
    def call(env)
      env[ProxyAuth::ENV_KEY] ||= LOGIN
      @app.call(env)
    end
  end
end
