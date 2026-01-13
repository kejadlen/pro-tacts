# frozen_string_literal: true

# Allow WebDAV methods (PROPFIND, REPORT) in addition to standard HTTP methods
supported_http_methods %w[GET HEAD OPTIONS PROPFIND REPORT]
