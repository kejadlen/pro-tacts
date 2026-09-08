
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

    # Whether to dump full request/response exchanges to the log. Off by
    # default because it logs contact data. See ProTacts::DebugLogger.
    #: () -> bool
    def debug?
      value = @env.fetch("PRO_TACTS_DEBUG", nil)
      !value.nil? && value.match?(TRUTHY)
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

    # Where requests the app could not answer are kept, one directory per
    # distinct request. Under log/ because it holds request data and is not
    # meant to be committed. See ProTacts::UnhandledRequests.
    #: () -> Pathname
    def unhandled_dir
      Pathname.new(@env.fetch("PRO_TACTS_UNHANDLED_DIR", "log/unhandled"))
    end

    # Where the debug logger writes. A path, overridable with
    # PRO_TACTS_DEBUG_LOG; "stderr" keeps it on the process's stderr.
    #: () -> String
    def debug_log_path
      @env.fetch("PRO_TACTS_DEBUG_LOG", "log/debug.log")
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
