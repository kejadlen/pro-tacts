
require "nokogiri"

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
    HEX = "0123456789abcdef"

    # The account name when no caller overrides it. A constant because
    # the install screen states the name the download is about to carry
    # and must not restate it as a second literal.
    DEFAULT_NAME = "pro-tacts"

    # The username and password are a throwaway fictional pair and the server
    # ignores them: identity comes from the Tailscale headers that serve
    # injects (see ProTacts::TailscaleAuth). They stay in the template
    # because the account form expects the fields; dropping them is
    # untested.
    #: (hostname: String, ?name: String) -> String
    def self.render(hostname:, name: DEFAULT_NAME)
      identifier = "#{IDENTIFIER_PREFIX}-#{unique_hex}"

      template % {
        hostname: escape(hostname),
        name: escape(name),
        identifier:,
        account_identifier: "#{identifier}.account",
        top_level_uuid: uuid,
        payload_uuid: uuid
      }
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
    def self.template
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>PayloadContent</key>
          <array>
            <dict>
              <key>PayloadType</key>
              <string>com.apple.carddav.account</string>
              <key>PayloadVersion</key>
              <integer>1</integer>
              <key>PayloadIdentifier</key>
              <string>%{account_identifier}</string>
              <key>PayloadUUID</key>
              <string>%{payload_uuid}</string>
              <key>PayloadDisplayName</key>
              <string>%{name}</string>
              <key>PayloadOrganization</key>
              <string>pro-tacts</string>
              <key>CardDAVAccountDescription</key>
              <string>%{name}</string>
              <key>CardDAVHostName</key>
              <string>%{hostname}</string>
              <key>CardDAVUsername</key>
              <string>alpha@example.com</string>
              <key>CardDAVPassword</key>
              <string>carddav-dev</string>
              <key>CardDAVUseSSL</key>
              <true/>
            </dict>
          </array>
          <key>PayloadDisplayName</key>
          <string>%{name} CardDAV</string>
          <key>PayloadIdentifier</key>
          <string>%{identifier}</string>
          <key>PayloadOrganization</key>
          <string>pro-tacts</string>
          <key>PayloadRemovalDisallowed</key>
          <false/>
          <key>PayloadScope</key>
          <string>User</string>
          <key>PayloadType</key>
          <string>Configuration</string>
          <key>PayloadUUID</key>
          <string>%{top_level_uuid}</string>
          <key>PayloadVersion</key>
          <integer>1</integer>
        </dict>
        </plist>
      XML
    end

    # CardDAVPrincipalURL is omitted on purpose: no Server Path, matching
    # the bare-hostname setup the working session used.

    #: (String text) -> String
    def self.escape(text)
      text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    #: () -> String
    def self.unique_hex
      "#{Time.now.utc.strftime('%Y%m%d%H%M%S%L')}#{rand(1 << 16).to_s(16)}"
    end

    #: () -> String
    def self.uuid
      [8, 4, 4, 4, 12].map { |n| Array.new(n) { HEX[rand(16)] }.join }.join("-")
    end
  end
end
