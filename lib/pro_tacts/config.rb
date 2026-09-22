
require "pathname"

module ProTacts
  # Single source of truth for configuration read from the environment.
  # Nothing else in the app should read ENV directly; add a method here and
  # read it through ProTacts.config instead.
  class Config
    # @rbs @env: Hash[String, String]

    TRUTHY = /\A(1|true|yes)\z/i #: Regexp

    #: (?Hash[String, String] env) -> void
    def initialize(env = ENV)
      @env = env
    end

    # Sentry DSN; nil when unset. A nil DSN is passed straight to
    # Sentry.init, which leaves the client inert — capture_message and
    # the rack middleware become no-ops.
    #: () -> String?
    def sentry_dsn
      @env.fetch("SENTRY_DSN", nil)
    end

    # Whether the exchange log keeps every DAV exchange rather than the
    # ones that went wrong, so a write that succeeded can be read back —
    # which is how a client's handling of a property gets probed at all
    # (docs/apple-contacts.md). Off by default because it records every
    # sync whole. See ProTacts::ExchangeLog.
    #: () -> bool
    def debug?
      value = @env.fetch("PRO_TACTS_DEBUG", nil)
      !value.nil? && value.match?(TRUTHY)
    end

    # A login to answer requests that name nobody, PRO_TACTS_DEFAULT_LOGIN;
    # nil when unset. A deployment behind a proxy leaves it unset, so the
    # proxy's Remote-User is the only identity (ProxyAuth). A deployment
    # with nothing in front — the preview app — names one, and StubLogin
    # writes it onto every request that arrives without the header, so the
    # app is reachable without a proxy. Never set where real data is
    # served: it hands every anonymous caller that login's address book.
    #: () -> String?
    def default_login
      value = @env.fetch("PRO_TACTS_DEFAULT_LOGIN", nil)
      value unless value.nil? || value.strip.empty?
    end

    # Root data directory: holds the contacts database, and the exported
    # card mirror once there is one. Overridable with
    # PRO_TACTS_DATA_DIR.
    #: () -> Pathname
    def data_dir
      Pathname.new(@env.fetch("PRO_TACTS_DATA_DIR", "data"))
    end

    # The contacts database: every card, the change log, and the index
    # derived from the cards (see ProTacts::Store). PRO_TACTS_DATABASE
    # overrides the whole path rather than a name under the data
    # directory, so a deployment can put the database on a different
    # volume from the exports.
    #: () -> Pathname
    def database_path
      path = @env.fetch("PRO_TACTS_DATABASE", nil)
      path.nil? ? data_dir / "contacts.db" : Pathname.new(path)
    end

    # Where the exchange log writes. A path, overridable with
    # PRO_TACTS_EXCHANGE_LOG; "stderr" keeps it on the process's stderr.
    # Under log/ because it holds request data and is not meant to be
    # committed. See ProTacts::ExchangeLog.
    #: () -> Pathname
    def exchange_log_path
      Pathname.new(@env.fetch("PRO_TACTS_EXCHANGE_LOG", data_dir / "log/exchange.log"))
    end

    # What this running server calls itself, PRO_TACTS_INSTANCE_NAME:
    # the CardDAV account a device installs and the browser tab both
    # carry it, so two pro-tacts servers can be told apart on the same
    # phone or in the same window.
    #: () -> String
    def instance_name
      @env.fetch("PRO_TACTS_INSTANCE_NAME", "pro-tacts")
    end

    # A Gloss accent to wear in place of the default, PRO_TACTS_ACCENT —
    # teal, clay, ink-blue, ochre, or plum (public/admin.css); nil keeps
    # the default and leaves the chrome unfilled.
    #: () -> String?
    def accent
      @env.fetch("PRO_TACTS_ACCENT", nil)
    end

    # The tab's icon, PRO_TACTS_FAVICON, as an href; nil leaves the page
    # without one, which is the deployment's "no brand mark"
    # (docs/DESIGN.md).
    #: () -> String?
    def favicon
      @env.fetch("PRO_TACTS_FAVICON", nil)
    end

    # The running image's version, baked in as a build arg (see
    # Dockerfile and the release job in ci.yml): the image tag, which is
    # the GitHub release's name too — `YYYYMMDD-HHmm-<short sha>`. One
    # string carrying when it was built and what from, and the one to
    # go look up.
    #
    # Blank is absent here: `ENV VERSION=${VERSION}` with no build arg
    # behind it sets an empty string, so an image built by hand says ""
    # where a process outside one says nothing at all, and neither names
    # a version.
    #: () -> String?
    def version
      value = @env.fetch("VERSION", nil)
      value unless value.nil? || value.strip.empty?
    end
  end
end
