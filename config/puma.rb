
# Puma replaces its default method list with this one rather than adding to
# it, so every method the app answers has to be named here or Puma rejects
# the request with a 501 before Rack sees it — and UnhandledRequests never
# gets to capture it. Keep this list matching the privileges advertised in
# current-user-privilege-set: DAV:write and DAV:bind imply PUT, DAV:unbind
# implies DELETE (RFC 3744 sections 3.2, 3.9, and 3.10).
supported_http_methods %w[GET HEAD OPTIONS PROPFIND REPORT PUT DELETE]
