# frozen_string_literal: true

require "nokogiri"

module ProTacts
  # Renders the configuration profile that provisions the pro-tacts CardDAV
  # account on macOS, so the resync loop is one rake command instead of the
  # Internet Accounts dance. Payload keys per Apple's Device Management
  # reference for com.apple.carddav.account.
  #
  # Every render carries a fresh identifier and fresh UUIDs: the account
  # identity follows the profile, so each install provisions a cold account
  # with no cached sync state — exactly what the experiment loop needs. The
  # cost is that reinstalling without removing first orphans the old account;
  # rake profile:remove sweeps every profile carrying our prefix.
  class Profile
    IDENTIFIER_PREFIX = "dev.kejadlen.pro-tacts.carddav"
    HEX = "0123456789abcdef"

    # Username and password are a throwaway fictional pair, inlined in the
    # template. Real auth is its own backlog task.
    def self.render(hostname:)
      identifier = "#{IDENTIFIER_PREFIX}-#{unique_hex}"

      template % {
        hostname: escape(hostname),
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
    def self.installed_identifiers(list_output)
      list_output.scan(/(?<![\w.-])#{Regexp.escape(IDENTIFIER_PREFIX)}-[\w.-]+/).uniq
    end

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
              <string>pro-tacts</string>
              <key>PayloadOrganization</key>
              <string>pro-tacts</string>
              <key>CardDAVAccountDescription</key>
              <string>pro-tacts</string>
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
          <string>pro-tacts CardDAV</string>
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

    def self.escape(text)
      text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def self.unique_hex
      "#{Time.now.utc.strftime('%Y%m%d%H%M%S%L')}#{rand(1 << 16).to_s(16)}"
    end

    def self.uuid
      [8, 4, 4, 4, 12].map { |n| Array.new(n) { HEX[rand(16)] }.join }.join("-")
    end
  end
end
