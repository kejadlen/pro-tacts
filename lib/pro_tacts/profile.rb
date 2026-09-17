require "digest"
require "securerandom"

require "nokogiri"

require "pro_tacts"

module ProTacts
  # Renders the configuration profile that provisions the pro-tacts CardDAV
  # account, so the resync loop is one rake command instead of the Internet
  # Accounts dance, and so a device that can reach the app can provision
  # itself from it (Web's /setup). Payload keys per Apple's Device
  # Management reference for com.apple.carddav.account.
  #
  # Every render carries a fresh identifier and fresh UUIDs: the account
  # identity follows the profile, so each install provisions a cold account
  # with no cached sync state — exactly what the experiment loop needs. The
  # cost is that reinstalling without removing first orphans the old account;
  # rake profile:remove sweeps every profile carrying our prefix and the
  # host it is configured for.
  #
  # The served route keeps that rule rather than deriving a stable identifier
  # from the account, which would make a reinstall a no-op: an identifier is
  # what a device replaces a profile by (Apple's Configuration Profile
  # Reference, on PayloadIdentifier — "This string is used to determine
  # whether a new profile should replace an existing one or should be
  # added"), so a stable one turns the second install into an update of
  # something already installed. Reinstalling is what someone does when sync
  # has gone wrong, and a cold account is the thing that fixes it; the
  # duplicate account that costs is visible and removable where the install
  # happened.
  class Profile
    IDENTIFIER_PREFIX = "dev.kejadlen.pro-tacts.carddav"

    # The server ignores the username and password: identity comes from
    # the header the proxy in front of it writes (see
    # ProTacts::ProxyAuth). /setup passes the requester's login anyway,
    # so the account says which tailnet user it is for. The password
    # stays a placeholder because the account form expects the field,
    # and dropping it is untested.
    #: (hostname: String, username: String) -> String
    def self.render(hostname:, username:)
      # The instance's name rather than a render parameter: a caller
      # passing its own would label an account no device installs.
      name = ProTacts.config.instance_name
      identifier = "#{IDENTIFIER_PREFIX}.#{host_digest(hostname)}.#{unique_hex}"

      builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |x|
        x.doc.create_internal_subset(
          "plist",
          "-//Apple//DTD PLIST 1.0//EN",
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd",
        )
        x.plist(version: "1.0") do
          x.dict do
            x.key "PayloadContent"
            x.array do
              x.dict do
                x.key "PayloadType"
                x.string "com.apple.carddav.account"
                x.key "PayloadVersion"
                x.integer 1
                x.key "PayloadIdentifier"
                x.string "#{identifier}.account"
                x.key "PayloadUUID"
                x.string SecureRandom.uuid
                x.key "PayloadDisplayName"
                x.string name
                x.key "PayloadOrganization"
                x.string "pro-tacts"
                x.key "CardDAVAccountDescription"
                x.string name
                x.key "CardDAVHostName"
                x.string hostname
                x.key "CardDAVUsername"
                x.string username
                x.key "CardDAVPassword"
                x.string "carddav-dev"
                x.key "CardDAVUseSSL"
                x.true
                # CardDAVPrincipalURL is omitted on purpose: no Server Path,
                # matching the bare-hostname setup the working session used.
              end
            end
            x.key "PayloadDisplayName"
            x.string "#{name} CardDAV"
            x.key "PayloadIdentifier"
            x.string identifier
            x.key "PayloadOrganization"
            x.string "pro-tacts"
            x.key "PayloadRemovalDisallowed"
            x.false
            x.key "PayloadScope"
            x.string "User"
            x.key "PayloadType"
            x.string "Configuration"
            x.key "PayloadUUID"
            x.string SecureRandom.uuid
            x.key "PayloadVersion"
            x.integer 1
          end
        end
      end
      builder.to_xml
    end

    # The host as one identifier segment, so an installed profile says
    # which server it provisions an account against. The host rather than
    # the account name, which defaults to the same "pro-tacts" whoever
    # rendered it, or the username, which is one login across both: two
    # profiles pointing at the same host are the same account, and two
    # pointing at different hosts never are.
    #
    # A digest rather than the host itself, which would read as a second
    # dotted name inside a dotted identifier. Hiding nothing — the profile
    # states the host a few keys down — so a short one is enough, and the
    # sweep recomputes it from the host it is configured for. Downcased
    # first, since a host differing only in case is the same server.
    #: (String hostname) -> String
    def self.host_digest(hostname)
      # The message names the argument rather than PRO_TACTS_HOSTNAME: the
      # rake tasks read that variable, /setup passes the request's host,
      # and only the caller knows which it was.
      if hostname.strip.empty?
        raise ArgumentError, "hostname is #{hostname.inspect}, so the profile would name no server. " \
          "Pass the host the app answers on, such as \"pro-tacts.example.ts.net\"."
      end

      Digest::SHA256.hexdigest(hostname.downcase)[0, 8] #: String
    end

    # Picks the identifiers of profiles provisioned against hostname out of
    # `profiles list` output, so profile:remove sweeps every profile
    # pointing at the server it is configured for and no others — a dev
    # sweep leaves the profile the deployment installed alone. Pass
    # hostname: nil for every pro-tacts profile whatever server it points
    # at, including the ones installed before the host was part of the
    # identifier.
    #
    # Scans for the identifier anywhere in the output rather than assuming a
    # key-value layout, since the listing format has changed across macOS
    # versions (key-value today, table under later releases).
    #: (String list_output, hostname: String?) -> Array[String]
    def self.installed_identifiers(list_output, hostname:)
      tail = if hostname
        /\.#{host_digest(hostname)}\.[\w-]+/
      else
        /[.-][\w.-]+/
      end

      # A pattern with no groups scans to whole matches, which is
      # narrower than the signature of String#scan can say.
      list_output.scan(/(?<![\w.-])#{Regexp.escape(IDENTIFIER_PREFIX)}#{tail}(?![\w.-])/).uniq #: Array[String]
    end

    #: () -> String
    def self.unique_hex
      "#{Time.now.utc.strftime('%Y%m%d%H%M%S%L')}#{rand(1 << 16).to_s(16)}"
    end
  end
end
