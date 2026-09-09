require "pro_tacts/admin/phlex"

require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /setup — the screen a device installs the CardDAV account
    # from. Until this existed the profile was rendered by rake on the
    # machine the repository is checked out on, so provisioning a phone
    # meant mailing a file to it; here the device that can reach the app
    # is the device that can provision itself from it.
    #
    # /setup rather than /profile: in a web app a profile is the reader's
    # own account page, and this is the device's setup — the one thing
    # somebody types after the hostname when a new phone arrives.
    #
    # The account it names is read off the request rather than out of
    # the environment (see Web's route), so the two facts worth stating
    # — which server, under which name — are the ones the download is
    # about to carry, not a copy of them.
    class DeviceSetup < Phlex::HTML
      # @rbs @hostname: String
      # @rbs @name: String

      #: (hostname: String, name: String) -> void
      def initialize(hostname:, name:)
        @hostname = hostname
        @name = name
      end

      def view_template
        render Layout.new(title: "Device setup") do
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/", class: "type-label") { "‹ contacts" }
            end
            div(class: "card") do
              div(class: "card-body") do
                h1(class: "type-h2", style: "margin: 0;") { "CardDAV profile" }
                dl(class: "detail-grid") do
                  dt(class: "type-label") { "server" }
                  dd(class: "type-body-sm") { @hostname }
                  dt(class: "type-label") { "account" }
                  dd(class: "type-body-sm") { @name }
                end
                a(href: "/setup/carddav.mobileconfig", class: "btn", data_variant: "primary") {
                  "download profile"
                }
              end
            end
          end
        end
      end
    end
  end
end
