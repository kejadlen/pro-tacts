
require "pathname"

module ProTacts
  # Single source of truth for configuration read from the environment.
  # Nothing else in the app should read ENV directly; add a method here and
  # read it through ProTacts.config instead.
  class Config
    TRUTHY = /\A(1|true|yes)\z/i

    def initialize(env = ENV)
      @env = env
    end

    # The deployment environment: APP_ENV wins, then RACK_ENV, then
    # "development".
    def environment
      @env.fetch("APP_ENV") { @env.fetch("RACK_ENV", "development") }
    end

    def test?
      environment == "test"
    end

    # Sentry DSN. Required at boot; raises if unset so the failure is loud.
    def sentry_dsn
      @env.fetch("SENTRY_DSN")
    end

    # Whether to dump full request/response exchanges to the log. Off by
    # default because it logs contact data. See ProTacts::DebugLogger.
    def debug?
      value = @env.fetch("PRO_TACTS_DEBUG", nil)
      !value.nil? && value.match?(TRUTHY)
    end

    # Root data directory: holds the contacts directory and, later, the
    # database. Overridable with PRO_TACTS_DATA_DIR.
    def data_dir
      Pathname.new(@env.fetch("PRO_TACTS_DATA_DIR", "data"))
    end

    # Contacts live at data/contacts, one KDL file per contact; the
    # filename is the contact ID. See
    # docs/plans/2026-01-12-carddav-architecture.md.
    def contacts_dir
      data_dir / "contacts"
    end

    # Where the debug logger writes. A path, overridable with
    # PRO_TACTS_DEBUG_LOG; "stderr" keeps it on the process's stderr.
    def debug_log_path
      @env.fetch("PRO_TACTS_DEBUG_LOG", "log/debug.log")
    end
  end
end
