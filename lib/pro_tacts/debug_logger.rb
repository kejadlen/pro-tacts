# frozen_string_literal: true

require "rack"

module ProTacts
  # Rack middleware that dumps the full request and response exchange to a
  # log stream: method, path, every header, and the full body on both sides.
  #
  # Off by default because it logs contact data. The only card right now is
  # fictional, so the debug path stays verbose while the normal one-line path
  # (Roda's common_logger) can be narrowed later without losing this.
  class DebugLogger
    def initialize(app, io: $stderr)
      @app = app
      @io = io
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
      text.to_s.each_line(chomp: true) { |line| @io.puts("#{prefix} #{line}") }
    end
  end
end
