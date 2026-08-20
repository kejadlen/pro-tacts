
require "fileutils"
require "logger"
require "pathname"
require "rack"

module ProTacts
  # Rack middleware that dumps the full request and response exchange to a
  # Logger: method, path, every header, and the full body on both sides.
  # Every line is prefixed ">>" (request) or "<<" (response) so multi-line
  # XML/vCard bodies stay readable.
  #
  # Off by default because it logs contact data. The only card right now is
  # fictional, so the debug path stays verbose while the normal one-line path
  # (Roda's common_logger) can be narrowed later without losing this.
  class DebugLogger
    # @rbs @app: Rack::_App
    # @rbs @logger: Logger

    # Builds the Logger the middleware writes to: appended and unbuffered
    # (Logger syncs its own device), one timestamped line per dump. path
    # "stderr" writes to the process's stderr.
    #: (String | Pathname path) -> Logger
    def self.open_log(path)
      target = if path.to_s == "stderr"
                 $stderr
               else
                 FileUtils.mkdir_p(Pathname.new(path).dirname)
                 path.to_s
               end

      Logger.new(target).tap do |logger|
        logger.level = :debug
        logger.formatter = proc do |_severity, datetime, _progname, msg|
          "#{datetime.strftime('%Y-%m-%dT%H:%M:%S.%3N')} #{msg}\n"
        end
      end
    end

    #: (Rack::_App app, logger: Logger) -> void
    def initialize(app, logger:)
      @app = app
      @logger = logger
    end

    #: (Rack::env env) -> Rack::response
    def call(env)
      log_request(env)
      status, headers, body = @app.call(env)
      parts = log_response(status, headers, body)
      [status, headers, parts]
    end

    private

    #: (Rack::env env) -> void
    def log_request(env)
      write(">>", "#{env.fetch('REQUEST_METHOD')} #{full_path(env)} #{env.fetch('SERVER_PROTOCOL')}")
      each_header(env) do |name, value|
        write(">>", "#{name}: #{value}")
      end
      body = read_request_body(env)
      write(">>", body) unless body.empty?
    end

    # Returns the body parts it consumed, for the caller to send on in
    # place of the body it read.
    #: (Integer status, Rack::headers headers, Rack::_Body body) -> Array[String]
    def log_response(status, headers, body)
      write("<<", "#{status}#{reason(status)}")
      headers.each do |name, value|
        write("<<", "#{name}: #{value}")
      end
      parts = [] #: Array[String]
      body.each do |part|
        parts << part
      end
      # A body holding a resource closes it. No signature can say
      # "close if you have one", so the cast carries what respond_to?
      # has already established.
      (_ = body).close if body.respond_to?(:close)
      write("<<", parts.join) unless parts.join.empty?
      parts
    end

    #: (Rack::env env) -> String
    def full_path(env)
      path = env["PATH_INFO"].to_s
      query = env["QUERY_STRING"].to_s
      query.empty? ? path : "#{path}?#{query}"
    end

    #: (Rack::env env) { (String, untyped) -> void } -> void
    def each_header(env)
      env.each do |key, value|
        case key
        when /\AHTTP_(.+)\z/
          yield header_name(key.delete_prefix("HTTP_")), value
        when "CONTENT_TYPE"
          yield "Content-Type", value
        when "CONTENT_LENGTH"
          yield "Content-Length", value
        end
      end
    end

    #: (String name) -> String
    def header_name(name)
      name.split("_").map(&:capitalize).join("-")
    end

    #: (Rack::env env) -> String
    def read_request_body(env)
      input = env["rack.input"]
      return "" if input.nil?
      body = input.read
      input.rewind
      body
    end

    #: (Integer status) -> String
    def reason(status)
      phrase = Rack::Utils::HTTP_STATUS_CODES[status]
      phrase ? " #{phrase}" : ""
    end

    #: (String prefix, String text) -> void
    def write(prefix, text)
      text.to_s.lines(chomp: true).each do |line|
        @logger.debug("#{prefix} #{line}")
      end
    end
  end
end
