
require "pathname"

require "pro_tacts"
require "sentry-ruby"

require "rack/rewindable_input"
require "roda"

require "pro_tacts/contact"
require "pro_tacts/cross_site"
require "pro_tacts/exchange_log"
require "pro_tacts/refusal_alerts"
require "pro_tacts/store"
require "pro_tacts/proxy_auth"
require "roda/plugins/dav_verbs"

module ProTacts
  class Web < Roda
    # @rbs @contacts: Array[Contact]?
    # @rbs @ctag: String?
    # @rbs @login: String
    # @rbs @book: Set[String]?

    # The vendored Gloss CSS and the admin app's own stylesheet (see
    # docs/DESIGN.md); relative to this file rather than $0 for the same
    # reason Store::MIGRATIONS is, and served by Roda's own `public`
    # plugin rather than by the proxy in front, which passes every
    # request through and writes the login on it (ProxyAuth).
    PUBLIC_ROOT = Pathname.new(
      __dir__ #: String
    ).parent.parent / "public" #: Pathname

    # The store this app serves from. config.ru builds it and hands it in;
    # nothing here reaches for a global to find one, which is what lets a
    # test point the app at a throwaway database. Kept in Roda's own opts
    # rather than a class variable, so it is frozen with the app and a
    # write after that raises instead of quietly taking effect.
    #: (Store store) -> void
    def self.store=(store)
      opts[:store] = store
    end

    #: () -> Store
    def self.store
      opts.fetch(:store) do
        raise "no store: hand one to ProTacts::Web.store= before serving"
      end
    end

    # RewindableInput lets the exchange log below read the request body
    # after the application has.
    use Rack::RewindableInput::Middleware
    use Sentry::Rack::CaptureExceptions

    # Inside CaptureExceptions, so the exchange tag lands on the scope it
    # opens for the request. Outside the route's identity gate
    # (the error handler below), and safe there because a 401 is not a failure it
    # keeps (ExchangeLog#failed?). The log opens when Roda builds the
    # stack, not here, so requiring the app writes nothing.
    use ProTacts::ExchangeLog, path: ProTacts.config.exchange_log_path, everything: ProTacts.config.debug?

    # Inside ExchangeLog, which marks the DAV exchanges this alerts on
    # and has already tagged the scope the warning is sent from.
    use ProTacts::RefusalAlerts

    plugin :all_verbs
    plugin :dav_verbs
    plugin :public, root: PUBLIC_ROOT.to_s
    plugin :hash_branches

    # A DAV 404 warns through RefusalAlerts; an admin one reports nothing.
    plugin :not_found do
      "Not Found"
    end

    # The identity gate's refusal, as an exception mapped to a
    # response: ProxyAuth.login raises MissingLogin for a request that
    # names nobody, and this answers it with the 401. `classes:` keeps
    # the plugin from touching any other raise — an unexpected failure
    # still propagates to Sentry::Rack::CaptureExceptions outside the
    # app, where it is reported, so this handler must not widen.
    #
    # A 401 must carry a challenge (RFC 9110 section 15.5.2), and
    # `Proxy-Identity` is no registered scheme: it tells the client
    # that the credential is the login its proxy vouches for, which
    # nothing the client could send supplies.
    #
    # The body names the header that was read, because the failure it
    # reports is almost always a proxy writing some other one. Naming
    # it hands an attacker nothing: the proxy overwrites the header on
    # every request, so knowing which one it is buys no way to forge
    # it.
    plugin :error_handler, classes: [ProxyAuth::MissingLogin] do |_e|
      response.status = 401
      response["WWW-Authenticate"] = "Proxy-Identity"
      response["Content-Type"] = "text/plain"
      "Unauthorized: no login on the #{ProxyAuth::HEADER} header.\n" \
      "The proxy in front of this app writes that header.\n"
    end

    # The router's trunk: the identity gate, the static files, and the
    # root the admin and DAV halves share. Every other first segment is
    # a hash_branch in lib/pro_tacts/web/, run on this same instance, so
    # what the trunk sets they see.
    route do |r|
      # Every request names a tailnet user or is refused — the static
      # files included — because #login raises for one that names
      # nobody and the error handler above answers it.
      @login = ProxyAuth.login(r.env)

      # A write another site's page sent, refused before any route
      # can apply it (CrossSite).
      if CrossSite.write?(r.env)
        response.status = 403
        response["Content-Type"] = "text/plain"
        response.write("Forbidden: a write from another site's page.\n")
        r.halt
      end

      r.public
      r.hash_branches

      r.is "" do
        # The dashboard home: the one human-facing screen's home
        # (docs/DESIGN.md), a GET alongside the PROPFIND below it —
        # same path, disjoint verbs, and a browser's plain GET is no
        # DAV client's bootstrap. The create dialog rides along hidden
        # in the render (see Admin::ContactDialog).
        r.get do
          dashboard(query: r.params["q"])
        end

        r.propfind do
          current_user_principal("/")
        end
      end
    end

    private

    #: () -> Store
    def store
      self.class.store
    end
  end
end

# The branches reopen Web, so they load once the plugins they call are in.
require "pro_tacts/web/api"
require "pro_tacts/web/contacts"
require "pro_tacts/web/dav"
require "pro_tacts/web/groups"
require "pro_tacts/web/import"
require "pro_tacts/web/setup"
