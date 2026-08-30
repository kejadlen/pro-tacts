
require "roda"

class Roda
  module RodaPlugins
    # Adds routing methods for WebDAV/CardDAV HTTP verbs.
    #
    # Only PROPFIND and REPORT are implemented here because they are the
    # two with no routing method in Roda itself; PUT arrives through
    # plugin :all_verbs. Other WebDAV verbs (PROPPATCH, MKCOL, COPY,
    # MOVE, LOCK, UNLOCK) would each need a line here when one is
    # answered.
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
