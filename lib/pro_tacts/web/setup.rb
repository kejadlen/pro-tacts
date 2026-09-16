require "pro_tacts/admin/device_setup"
require "pro_tacts/profile"

module ProTacts
  class Web < Roda
    # The configuration profile, served so the device reading this can
    # provision itself: until this route existed the only renderer was
    # the Rakefile, so putting the account on a phone meant running
    # rake on the machine holding the checkout and mailing the file
    # over. It is now the only renderer — rake profile:install downloads
    # from here. The screen and the document are separate paths because a
    # mobileconfig is not a page — the screen says what the download
    # will do, and only the link fires the install flow.
    #
    # The hostname is the request's rather than PRO_TACTS_HOSTNAME:
    # the address a device reached this app at is reachable from that
    # device by construction, where an environment variable is a claim
    # about some other machine's idea of where we live. It is the
    # client's Host header, which behind `tailscale serve` is serve's
    # own — and past the identity gate in web.rb's trunk, the only
    # devices asking are on the tailnet.
    hash_branch("setup") do |r|
      r.is do
        r.get do
          response["Content-Type"] = "text/html; charset=utf-8"
          Admin::DeviceSetup.call(hostname: r.host, name: Profile.account_name)
        end
      end

      # The media type is what starts the install: a device offers to
      # install a profile because of what the response is, not what the
      # path is called. The path carries .mobileconfig anyway, so a
      # download that does land in a file system lands under the name
      # the rake task writes. No Content-Disposition — an attachment
      # disposition on this type is untested here, and the install flow
      # is the point.
      r.get "carddav.mobileconfig" do
        response["Content-Type"] = "application/x-apple-aspen-config"
        Profile.render(hostname: r.host, username: @login)
      end

      # Names the requester's own book, `rake book:name` for whoever is
      # asking (docs/plans/2026-09-16-book-names.md); no name goes back
      # to the login. Plain text, for curl rather than a screen.
      r.post "book" do
        response["Content-Type"] = "text/plain"
        begin
          store.name_book(@login, r.params["name"]&.to_s)
          "#{@login} syncs #{Store::SYNC_PREFIX}#{store.book_name(@login) || @login}\n"
        rescue Sequel::UniqueConstraintViolation, Store::EveryonesBookName
          # Another login's name, a group's already, or everyone's.
          response.status = 409
          "#{Store::SYNC_PREFIX}#{r.params['name'].to_s.strip} is taken; #{@login}'s book is unchanged.\n"
        end
      end
    end
  end
end
