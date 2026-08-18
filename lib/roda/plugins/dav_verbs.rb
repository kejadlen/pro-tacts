
require "roda"

class Roda
  module RodaPlugins
    # Adds routing methods for WebDAV/CardDAV HTTP verbs.
    #
    # Only PROPFIND and REPORT are implemented since this is a read-only
    # CardDAV server. PROPFIND handles discovery and property retrieval,
    # REPORT handles addressbook-query and addressbook-multiget requests.
    #
    # Other WebDAV verbs (PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK)
    # would be needed for write support.
    module DavVerbs
      module RequestMethods
        %w[propfind report].each do |verb|
          class_eval(<<-END, __FILE__, __LINE__ + 1)
            def #{verb}(*args, &block)
              _verb(args, &block) if env["REQUEST_METHOD"] == "#{verb.upcase}"
            end
          END
        end
      end
    end

    register_plugin(:dav_verbs, DavVerbs)
  end
end
