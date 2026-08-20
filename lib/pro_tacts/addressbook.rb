require "digest"

require "pro_tacts/contact"

module ProTacts
  # The address book collection: every contact under the contacts
  # directory, plus the collection-wide state derived from those members.
  # The ctag changes when any card is added, removed, or changed and
  # nothing else, so a client comparing two of them learns whether a
  # resync is needed — never what changed.
  class Addressbook < Data.define(:contacts)
    def self.load(directory)
      new(contacts: Contact.all(directory))
    end

    # Sorting the id-and-etag lines makes the value independent of
    # directory listing order while staying sensitive to membership and
    # content.
    def ctag
      Digest::SHA256.hexdigest(contacts.map { "#{it.id} #{it.etag}" }.sort.join("\n"))
    end

    # Sync tokens are opaque to the client (RFC 6578 section 3); the URI
    # form is conventional. Built on the ctag so a client polling either
    # one sees changes at the same points.
    def sync_token
      "http://pro-tacts/sync/#{ctag}"
    end
  end
end
