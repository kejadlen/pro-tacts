# frozen_string_literal: true

require "nokogiri"

module ProTacts
  # Renders the configuration profile that provisions the pro-tacts CardDAV
  # account on macOS, so the resync loop is `rake profile` plus one
  # `profiles install` instead of the Internet Accounts dance. Payload keys
  # per Apple's Device Management reference for com.apple.carddav.account.
  #
  # UUIDs are fixed so reinstalling replaces the profile in place and
  # `profiles remove -identifier` always targets the same one.
  class Profile
    PAYLOAD_IDENTIFIER = "dev.kejadlen.pro-tacts.carddav"
    TOP_LEVEL_UUID = "6F1E2D3C-4B5A-4E7F-8C9D-0A1B2C3D4E5F"
    PAYLOAD_UUID = "7A2F3E4D-5C6B-4F80-9DAE-1B2C3D4E5F6A"

    # Username and password are a throwaway fictional pair, inlined in the
    # template. Real auth is its own backlog task.
    def self.render(hostname:)
      template % { hostname: escape(hostname) }
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
              <string>#{PAYLOAD_IDENTIFIER}.account</string>
              <key>PayloadUUID</key>
              <string>#{PAYLOAD_UUID}</string>
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
          <string>#{PAYLOAD_IDENTIFIER}</string>
          <key>PayloadOrganization</key>
          <string>pro-tacts</string>
          <key>PayloadRemovalDisallowed</key>
          <false/>
          <key>PayloadScope</key>
          <string>User</string>
          <key>PayloadType</key>
          <string>Configuration</string>
          <key>PayloadUUID</key>
          <string>#{TOP_LEVEL_UUID}</string>
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
  end
end
