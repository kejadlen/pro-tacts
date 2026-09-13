
require "pathname"

require "pro_tacts"
require "sentry-ruby"

require "rack/rewindable_input"
require "roda"

require "pro_tacts/debug_logger"
require "pro_tacts/contact"
require "pro_tacts/store"
require "pro_tacts/tailscale_auth"
require "pro_tacts/unhandled_requests"
require "roda/plugins/dav_verbs"

module ProTacts
  class Web < Roda
    # @rbs @contacts: Array[Contact]?
    # @rbs @ctag: String?
    # @rbs @identity: TailscaleAuth::Identity
    # @rbs @book: Set[String]?

    # The vendored Gloss CSS and the admin app's own stylesheet (see
    # docs/DESIGN.md); relative to this file rather than $0 for the same
    # reason Store::MIGRATIONS is, and served by Roda's own `public`
    # plugin rather than a reverse proxy — there is no reverse proxy
    # here, `tailscale serve` hands requests straight to this app.
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

    # RewindableInput allows us to read the request body for Sentry logging
    # and then rewind it so the application can still access it.
    use Rack::RewindableInput::Middleware
    use Sentry::Rack::CaptureExceptions

    # Outside the route's identity gate (#unauthorized), and safe there
    # because a refusal is a 401, which it does not keep
    # (UnhandledRequests.capture?): a refused request is not missing
    # functionality, and recording one would write an unauthenticated
    # body to disk.
    use ProTacts::UnhandledRequests, directory: ProTacts.config.unhandled_dir

    # Outside the identity gate too, so a refused request is dumped with
    # the rest. That is the point of a debug log, which is off by default
    # and kept on a local machine.
    if ProTacts.config.debug?
      logger = ProTacts::DebugLogger.open_log(ProTacts.config.debug_log_path)
      use ProTacts::DebugLogger, logger: logger
    end

    plugin :all_verbs
    plugin :dav_verbs
    plugin :public, root: PUBLIC_ROOT.to_s
    plugin :hash_branches

    plugin :not_found do
      Sentry.capture_message("404 Not Found", level: :warning)
      "Not Found"
    end

    # The router's trunk: the identity gate, the static files, and the
    # root the admin and DAV halves share. Every other first segment is
    # a hash_branch in lib/pro_tacts/web/, run on this same instance, so
    # what the trunk sets they see.
    route do |r|
      # Every request names a tailnet user or is refused, the static
      # files included (ProTacts::TailscaleAuth).
      @identity = TailscaleAuth.identity(r.env) || unauthorized(r)

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

    # The refusal of a request that names nobody. A 401 must carry a
    # challenge (RFC 9110 section 15.5.2), and `Tailscale` is no
    # registered scheme: it tells the client that the credential is its
    # tailnet identity, which nothing it could send supplies.
    #: (Roda::RodaRequest r) -> bot
    def unauthorized(r)
      response.status = 401
      response["WWW-Authenticate"] = "Tailscale"
      response["Content-Type"] = "text/plain"
      response.write("Unauthorized: no Tailscale identity on this request.\n")
      r.halt
    end

    #: () -> Store
    def store
      self.class.store
    end
  end
end

# The branches reopen Web, so they load once the plugins they call are in.
require "pro_tacts/web/contacts"
require "pro_tacts/web/dav"
require "pro_tacts/web/groups"
require "pro_tacts/web/setup"
