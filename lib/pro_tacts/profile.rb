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
  # rake profile:remove sweeps every profile carrying our prefix.
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

    # The account name when the environment names none. A constant
    # because the install screen states the name the download is about
    # to carry and must not restate it as a second literal.
    DEFAULT_NAME = "pro-tacts"

    # The name every render and the install screen state. A method
    # rather than a render parameter because there is only one source
    # for it: a caller passing a name of its own would be labelling an
    # account no device installs.
    #: () -> String
    def self.account_name
      ProTacts.config.profile_name || DEFAULT_NAME
    end

    # The server ignores the username and password: identity comes from
    # the Tailscale headers that serve injects (see
    # ProTacts::TailscaleAuth). /setup passes the requester's login
    # anyway, so the account says which tailnet user it is for. The
    # password stays a placeholder because the account form expects the
    # field, and dropping it is untested.
    #: (hostname: String, username: String) -> String
    def self.render(hostname:, username:)
      identifier = "#{IDENTIFIER_PREFIX}-#{unique_hex}"
      name = account_name

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

    # Picks our profile identifiers out of `profiles list` output so
    # profile:remove can sweep every pro-tacts profile, not just the latest.
    # Scans for the prefix anywhere in the output rather than assuming a
    # key-value layout, since the listing format has changed across macOS
    # versions (key-value today, table under later releases).
    #: (String list_output) -> Array[String]
    def self.installed_identifiers(list_output)
      # A pattern with no groups scans to whole matches, which is
      # narrower than the signature of String#scan can say.
      list_output.scan(/(?<![\w.-])#{Regexp.escape(IDENTIFIER_PREFIX)}-[\w.-]+/).uniq #: Array[String]
    end

    #: () -> String
    def self.unique_hex
      "#{Time.now.utc.strftime('%Y%m%d%H%M%S%L')}#{rand(1 << 16).to_s(16)}"
    end
  end
end
