require "pro_tacts"
require "pro_tacts/proxy_auth"

module ProTacts
  # Rack middleware that writes a login to Remote-User, the way the proxy
  # in front of a deployment does, so a server with nothing in front
  # answers instead of refusing every request (ProxyAuth, Web#unauthorized).
  # A request that already carries the header keeps its own, so `curl -H`
  # can still ask as someone else.
  #
  # It stands in for the proxy, so it belongs only where there is none:
  # the dev server (dev.ru) and the preview app, which names the login in
  # PRO_TACTS_DEFAULT_LOGIN and config.ru inserts it. A deployment that
  # serves real data leaves that unset and keeps the proxy as the only way
  # in — the app trusts whatever it is handed, so writing a login here in
  # front of one would hand every anonymous caller that address book.
  class StubLogin
    # @rbs @app: untyped
    # @rbs @login: String

    # The dev server's login; the preview passes its own.
    LOGIN = "alpha@example.com" #: String

    #: (untyped app, ?String login) -> void
    def initialize(app, login = LOGIN)
      @app = app
      @login = login
    end

    #: (Rack::env env) -> untyped
    def call(env)
      env[ProxyAuth::ENV_KEY] ||= @login
      @app.call(env)
    end
  end
end
