# frozen_string_literal: true

require "fileutils"
require "logger"
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
    # Builds the Logger the middleware writes to: appended and unbuffered
    # (Logger syncs its own device), one timestamped line per dump. path
    # "stderr" writes to the process's stderr.
    def self.open_log(path)
      target = if path == "stderr"
                 $stderr
               else
                 FileUtils.mkdir_p(File.dirname(path))
                 path
               end

      Logger.new(target).tap do |logger|
        logger.level = :debug
        logger.formatter = proc do |_severity, datetime, _progname, msg|
          "#{datetime.strftime('%Y-%m-%dT%H:%M:%S.%3N')} #{msg}\n"
        end
      end
    end

    def initialize(app, logger:)
      @app = app
      @logger = logger
    end

    def call(env)
      log_request(env)
      status, headers, body = @app.call(env)
      parts = log_response(status, headers, body)
      [status, headers, parts]
    end

    private

    def log_request(env)
      write(">>", "#{env['REQUEST_METHOD']} #{full_path(env)} #{env['SERVER_PROTOCOL']}")
      each_header(env) { |name, value| write(">>", "#{name}: #{value}") }
      body = read_request_body(env)
      write(">>", body) unless body.empty?
    end

    def log_response(status, headers, body)
      write("<<", "#{status}#{reason(status)}")
      headers.each { |name, value| write("<<", "#{name}: #{value}") }
      parts = []
      body.each { |part| parts << part }
      body.close if body.respond_to?(:close)
      write("<<", parts.join) unless parts.join.empty?
      parts
    end

    def full_path(env)
      path = env["PATH_INFO"].to_s
      query = env["QUERY_STRING"].to_s
      query.empty? ? path : "#{path}?#{query}"
    end

    def each_header(env)
      env.each do |key, value|
        case key
        when /\AHTTP_(.+)\z/
          yield header_name(Regexp.last_match(1)), value
        when "CONTENT_TYPE"
          yield "Content-Type", value
        when "CONTENT_LENGTH"
          yield "Content-Length", value
        end
      end
    end

    def header_name(name)
      name.split("_").map(&:capitalize).join("-")
    end

    def read_request_body(env)
      input = env["rack.input"]
      return "" if input.nil?
      body = input.read
      input.rewind
      body
    end

    def reason(status)
      phrase = Rack::Utils::HTTP_STATUS_CODES[status]
      phrase ? " #{phrase}" : ""
    end

    def write(prefix, text)
      text.to_s.each_line(chomp: true) { |line| @logger.debug("#{prefix} #{line}") }
    end
  end
end
