# Puma replaces its default method list with this one rather than adding to
# it, so every method the app answers has to be named here or Puma rejects
# the request with a 501 before Rack sees it — and UnhandledRequests never
# gets to capture it. PUT and DELETE are named here though the collection
# now advertises DAV:read alone, because the routes still answer and a
# write a client sends anyway is the observation this list must not
# swallow — docs/plans/2026-09-09-a-read-only-collection.md. POST is the
# web UI's alone — the browser's create, no DAV meaning.
supported_http_methods %w[GET HEAD OPTIONS PROPFIND REPORT PUT DELETE POST]
