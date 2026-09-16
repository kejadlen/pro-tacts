require "pro_tacts"
require "pro_tacts/proxy_auth"

module ProTacts
  # Rack middleware that writes a fixed login to Remote-User, the way the
  # proxy in front of a deployment does, so a dev server answers without
  # one. A request that already carries the header keeps its own, so
  # `curl -H` can still ask as someone else. Only dev.ru uses it.
  class DevLogin
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
