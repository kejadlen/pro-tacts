require "base64"

require "pro_tacts/vcard"

# Builds the cards macOS Contacts sends for a contact with a picture,
# in the exact wire shapes of the two captures in log/unhandled
# (put-...-1a6555e1 for the memoji, put-...-ae05fe03 for the photo).
# The captures stay unpromoted — possibly real images, see
# test/fixtures/macos-exchange/README.md — so the shapes live here as
# structure with synthetic payloads standing in for the pictures.
#
# What the captures carry, and this reproduces:
#
# - PHOTO's parameter section is one physical line ending at the
#   colon, unfolded however long it is: 99 octets for a photo, 1,685
#   for a memoji, whose VND-63-MEMOJI-DETAILS parameter (a base64
#   binary plist) is most of those octets. RFC 2426 section 2.6's
#   75-octet limit is a SHOULD the client meets only after the colon.
# - The base64 payload is inline (ENCODING=b, TYPE=JPEG — never a
#   URI), folded one break below the parameters: every continuation is
#   a single space then 76 octets of payload.
# - X-IMAGETYPE:PHOTO sits directly above PHOTO, and the token
#   X-ABCROP-RECTANGLE ends with is X-IMAGEHASH's value.
#
# The cards land within a percent of the captures' own sizes; the two
# dimensions that define the shapes — the parameter lines' 97 and
# 1,683 octets — match exactly.
module PhotoCard
  # The token naming the image in both X-IMAGEHASH and the crop
  # rectangle's tail, matching the captures' shape: 24 octets ending
  # "==", the encoding of a 16-byte hash.
  IMAGE_HASH = Base64.strict_encode64("pro-tacts-image!") #: String

  # A photo's parameters (capture ae05fe03): a real crop — origin
  # (38,0), not the whole image — then the encoding pair.
  PHOTO_PARAMETERS = [
    "X-ABCROP-RECTANGLE=ABClipRect_1&38&0&769&768&#{IMAGE_HASH}",
    "ENCODING=b",
    "TYPE=JPEG",
  ] #: Array[String]

  # A memoji's parameters (capture 1a6555e1): the crop is the whole
  # image, and VND-63-MEMOJI-DETAILS sits between it and the encoding
  # pair. The capture's whole parameter section runs 1,683 octets on
  # one physical line, so the value is sized to land this on that
  # number — past 75 by an order of magnitude, which is the dimension
  # that matters, at the capture's own mark. The capture's own value
  # is a base64 binary plist; synthetic base64 stands in, since
  # nothing on the server decodes it.
  MEMOJI_LINE = 1_683 #: Integer
  MEMOJI_CROP = "X-ABCROP-RECTANGLE=ABClipRect_1&0&0&420&420&#{IMAGE_HASH}" #: String
  MEMOJI_DETAILS_BYTES =
    (MEMOJI_LINE - "PHOTO;#{MEMOJI_CROP};VND-63-MEMOJI-DETAILS=".length - ";ENCODING=b;TYPE=JPEG:".length)
      .then { it - it % 4 } # base64 characters come four to three bytes
      .then { it / 4 * 3 } #: Integer
  MEMOJI_PARAMETERS = [
    MEMOJI_CROP,
    "VND-63-MEMOJI-DETAILS=#{Base64.strict_encode64("m" * MEMOJI_DETAILS_BYTES)}",
    "ENCODING=b",
    "TYPE=JPEG",
  ] #: Array[String]

  # The photo property as the client folds it, per the module comment:
  # parameters unbroken on one line, payload a space then 76 octets a
  # continuation. Deliberately not VCard.fold, which honors the
  # 75-octet limit the client ignores here — this half builds what
  # arrives, and the writer's half is VCard's.
  #: (Array[String] parameters, String image_bytes) -> String
  def self.property(parameters, image_bytes)
    base64 = Base64.strict_encode64(image_bytes)
    continuations = base64.scan(/.{1,76}/).map { " #{it}" }
    "PHOTO;#{parameters.join(';')}:\r\n#{continuations.join("\r\n")}\r\n"
  end

  # Synthetic image bytes: never decoded — a card's payload is stored
  # and served as the base64 text it arrives as — so a repeating
  # pattern stands in, deterministic so a fixture's etag does not vary
  # per run. Binary, as decoded bytes are: the JPEG signature is not
  # UTF-8, and the equality a test wants against Base64's output is
  # byte equality, which a UTF-8 flag would break.
  #: (Integer bytes) -> String
  def self.image(bytes)
    ("\xFF\xD8\xFF\xE0".b + "synthetic photo payload".b * (bytes / 22 + 1)).byteslice(0, bytes)
  end

  # A card with a real photo attached: the 338 KB capture's shape. A
  # 242,925-byte image is the capture's size, because the client does
  # not downscale before sending — photos are the sizing case.
  #: (String id, ?bytes: Integer, ?extra: Array[String]) -> String
  def self.photo(id, bytes: 242_925, extra: [])
    card(id, property(PHOTO_PARAMETERS, image(bytes)), extra:)
  end

  # A card with a memoji attached: the 34 KB capture's shape, whose
  # parameter section runs 1,685 octets unfolded on one line.
  #: (String id, ?extra: Array[String]) -> String
  def self.memoji(id, extra: [])
    card(id, property(MEMOJI_PARAMETERS, image(23 * 1024)), extra:)
  end

  # The card around the picture trio, the capture's own lines: the
  # trio sits between NOTE and REV, and `extra` lands above it, which
  # is where the captures carry their BDAY.
  #: (String id, String photo_property, extra: Array[String]) -> String
  def self.card(id, photo_property, extra: [])
    [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "PRODID:-//Apple Inc.//macOS 26.5.1//EN",
      "N:Lovelace;Ada;;;",
      "FN:Ada Lovelace",
      "EMAIL;type=INTERNET;type=pref:ada@example.com",
      "TEL;type=CELL;type=VOICE;type=pref:+1-555-0100",
      "X-ADDRESSING-GRAMMAR;type=pref:#{Base64.strict_encode64("addressing-grammar")}",
      "ADR;type=HOME;type=pref:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom",
      "NOTE:Test",
      *extra,
      "X-IMAGEHASH:#{IMAGE_HASH}",
      "X-IMAGETYPE:PHOTO",
      photo_property,
      "REV:2026-08-25T03:15:06Z",
      "UID:#{id}",
      "END:VCARD",
    ].join("\r\n") + "\r\n"
  end
end
