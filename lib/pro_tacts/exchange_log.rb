require "fileutils"
require "logger"
require "pathname"
require "rack"
require "securerandom"
require "sentry-ruby"

module ProTacts
  # Rack middleware that writes the DAV exchanges that went wrong to a
  # local log, whole: the request line, every header, and both bodies,
  # photo bytes included. Sentry says that an exchange went wrong and
  # this log says what it was; card content reaches only the second
  # (docs/plans/2026-09-13-dav-observability.md, amended by
  # docs/plans/2026-09-13-failed-exchanges-only.md).
  #
  # Each DAV exchange gets an id, set as the `exchange` tag on the
  # request's Sentry scope and written at the head of each of its lines
  # here, so an alert names the exchange to read.
  class ExchangeLog
    # @rbs @app: Rack::_App
    # @rbs @logger: Logger
    # @rbs @everything: bool

    # Identifies this log's lines to Sentry's sentry_logger breadcrumb
    # hook, which keys its exclude list on the progname (see config.ru):
    # the lines carry card content, and send_default_pii has no say over
    # breadcrumbs.
    PROGNAME = "ProTacts::ExchangeLog" #: String

    # Where a DAV exchange's id rides in the env, which is how
    # RefusalAlerts tells a DAV exchange from an admin one.
    ENV_KEY = "pro_tacts.exchange" #: String

    # A photo PUT is a megabyte of base64 on its own.
    ROTATE_AT = 10 * 1024 * 1024 #: Integer
    ROTATIONS = 5 #: Integer

    # The paths the DAV half routes. The verbs the admin screens answer
    # are the other test: any other verb is a DAV client's wherever it
    # lands, which is what catches the PROPFIND on / and a DAV request
    # to a path nothing routes.
    DAV_PATH = %r{\A/(dav|\.well-known)(/|\z)} #: Regexp
    WEB_VERBS = %w[GET HEAD POST].freeze #: Array[String]

    # Builds the Logger the middleware writes to: appended, unbuffered
    # (Logger syncs its own device), and rotated by size. path "stderr"
    # writes to the process's stderr instead.
    #: (String | Pathname path) -> Logger
    def self.open_log(path)
      target = if path.to_s == "stderr"
                 $stderr
               else
                 FileUtils.mkdir_p(Pathname.new(path).dirname)
                 path.to_s
               end

      Logger.new(target, ROTATIONS, ROTATE_AT).tap do |logger|
        logger.level = :info
        logger.formatter = proc do |_severity, datetime, _progname, msg|
          stamp = datetime.strftime("%Y-%m-%dT%H:%M:%S.%3N")
          msg.to_s.lines.map { "#{stamp} #{it}" }.join
        end
      end
    end

    # Reads one exchange's request back out of the log at path or a
    # rotation of it: the request line and headers as logged, and the
    # body byte for byte. nil when none of them holds the id.
    #: (String id, String | Pathname path) -> [Array[String], String]?
    def self.read_request(id, path)
      marker = "#{id} >> ".b
      # Logger's rotations, newest first (Logger::LogDevice#shift_log_age).
      [path.to_s, *(0...ROTATIONS).map { "#{path}.#{it}" }].each do |log|
        next unless File.exist?(log)

        lines = File.binread(log).split("\n").filter_map do |line|
          _stamp, _, rest = line.partition(" ")
          rest.delete_prefix(marker) if rest.start_with?(marker)
        end
        next if lines.empty?

        blank = lines.index("") or raise ArgumentError, "exchange #{id} in #{log} has no blank line after its head"
        return [lines.take(blank), lines.drop(blank + 1).join("\n")]
      end
      nil
    end

    # everything logs every DAV exchange rather than the ones that went
    # wrong (Config#debug?).
    #: (Rack::_App app, path: String | Pathname, everything: bool) -> void
    def initialize(app, path:, everything:)
      @app = app
      @logger = self.class.open_log(path)
      @everything = everything
    end

    #: (Rack::env env) -> Rack::response
    def call(env)
      return @app.call(env) unless dav?(env)

      id = SecureRandom.hex(6)
      env[ENV_KEY] = id
      Sentry.set_tags(exchange: id)
      # The hub's last event id moves only for an error event, so one
      # that moved while the app ran is a report about this exchange.
      reported = Sentry.last_event_id

      status, headers, body = begin
        @app.call(env)
      rescue StandardError => e
        # CaptureExceptions reports it once this re-raises, under the
        # tag already set.
        write(id, request(env) + prefixed("!!", "#{e.class}: #{e.message}"))
        raise
      end

      unless @everything || failed?(status) || Sentry.last_event_id != reported
        return [status, headers, body]
      end

      parts = drain(body)
      write(id, request(env) + response(status, headers, parts.join))
      [status, headers, parts]
    end

    private

    #: (Rack::env env) -> bool
    def dav?(env)
      env["PATH_INFO"].to_s.match?(DAV_PATH) || !WEB_VERBS.include?(env["REQUEST_METHOD"])
    end

    # A 401 is the identity gate refusing a request that names nobody
    # (Web#unauthorized): nothing went wrong, and unless everything is
    # asked for, a body from outside the tailnet stays off disk.
    #: (Integer status) -> bool
    def failed?(status)
      status >= 400 && status != 401
    end

    #: (Rack::_Body body) -> Array[String]
    def drain(body)
      parts = [] #: Array[String]
      body.each do |part|
        parts << part
      end
      # A body holding a resource closes it. No signature can say
      # "close if you have one", so the cast carries what respond_to?
      # has already established.
      (_ = body).close if body.respond_to?(:close)
      parts
    end

    #: (Rack::env env) -> Array[String]
    def request(env)
      head = ["#{env.fetch('REQUEST_METHOD')} #{full_path(env)} #{env.fetch('SERVER_PROTOCOL')}"]
      env.each do |key, value|
        case key
        when /\AHTTP_(.+)\z/ then head << "#{header_name(key.delete_prefix('HTTP_'))}: #{value}"
        when "CONTENT_TYPE" then head << "Content-Type: #{value}"
        when "CONTENT_LENGTH" then head << "Content-Length: #{value}"
        end
      end
      message(">>", head, request_body(env))
    end

    #: (Integer status, Rack::headers headers, String body) -> Array[String]
    def response(status, headers, body)
      head = ["#{status}#{reason(status)}"]
      headers.each do |name, value|
        Array(value).each { head << "#{name}: #{it}" }
      end
      message("<<", head, body)
    end

    # Laid out as HTTP lays out a message, so that read_request can take
    # it apart: the head, a blank line, then the body split on "\n"
    # alone, which keeps each CR and leaves a final newline as an empty
    # last line.
    #: (String prefix, Array[String] head, String body) -> Array[String]
    def message(prefix, head, body)
      (head + [""] + body.b.split("\n", -1)).map { "#{prefix} #{it}".b }
    end

    #: (Rack::env env) -> String
    def full_path(env)
      path = env["PATH_INFO"].to_s
      query = env["QUERY_STRING"].to_s
      query.empty? ? path : "#{path}?#{query}"
    end

    #: (String name) -> String
    def header_name(name)
      name.split("_").map(&:capitalize).join("-")
    end

    # Read from the start whether or not the app read it first;
    # Rack::RewindableInput is what makes the rewind possible.
    #: (Rack::env env) -> String
    def request_body(env)
      input = env["rack.input"]
      return "" if input.nil?

      input.rewind
      body = input.read.to_s
      input.rewind
      body
    end

    #: (Integer status) -> String
    def reason(status)
      phrase = Rack::Utils::HTTP_STATUS_CODES[status]
      phrase ? " #{phrase}" : ""
    end

    # Binary, like message's lines, so an exception message that is not
    # UTF-8 still joins them.
    #: (String prefix, String text) -> Array[String]
    def prefixed(prefix, text)
      text.b.lines(chomp: true).map { "#{prefix} #{it}".b }
    end

    # One Logger call per exchange, so its lines land together however
    # many requests are running; the progname is what Sentry's hook
    # reads, and the formatter ignores it.
    #: (String id, Array[String] lines) -> void
    def write(id, lines)
      @logger.add(Logger::INFO, lines.map { "#{id} ".b + it + "\n" }.join, PROGNAME)
    end
  end
end
