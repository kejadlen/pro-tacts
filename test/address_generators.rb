require "hegel"

require "pro_tacts/admin/card_form"
require "pro_tacts/contact"

# Addresses as the app holds them — built through the constructor
# every path shares, the form's, a store row's, and a card's reading
# alike — drawn heavy in what a card's round trip has to carry back:
# the characters the escapes give meaning to in the components, and
# every spelling of a label the editor or a client can hand over.
module AddressGenerators
  include Hegel::Syntax::Methods

  # test_vcard.rb's ESCAPEY, with the blanks a reading might trim.
  PIECES = %W[; , \\ \\; \\\\ \\n \n \r\n \s \t a].freeze #: Array[String]

  def awkward_text = one_of(text(max_size: 12, min_codepoint: 1), arrays(sampled_from(PIECES), max_size: 6).map(&:join))

  def cased(tc, word) = word.chars.map { tc.draw(booleans) ? it.upcase : it }.join

  def padded(tc, word) = "#{tc.draw(sampled_from(["", " ", "  "]))}#{word}#{tc.draw(sampled_from(["", " ", "\t"]))}"

  def type_word = composite { |tc| padded(tc, cased(tc, tc.draw(sampled_from(%w[home work])))) }

  def other_word = composite { |tc| padded(tc, cased(tc, "other")) }

  def custom_word = one_of(sampled_from(["Summer house", "pref", "home, postal", "home work", ",", " "]), awkward_text)

  # Every spelling of a label: none, a type word, Apple's Other, a
  # comma list of type words with gaps, a custom word, and any of
  # those under Apple's wrapping, once or twice.
  def labels
    word = one_of(
      type_word,
      other_word,
      arrays(one_of(type_word, just("")), min_size: 2, max_size: 4).map { it.join(",") },
      custom_word,
    )
    wrapped = composite { |tc|
      depth = tc.draw(integers(min_value: 0, max_value: 2))
      depth.times.reduce(tc.draw(word)) { |label, _| "_$!<#{label}>!$_" }
    }
    optional(wrapped)
  end

  # An address as either path builds one: a card's reading, or the
  # editor's form over a row of either.
  def addresses = one_of(read_addresses, form_addresses)

  # A reading's components carry no carriage return — a bare CR ends no
  # line a card can carry (VCard::Parser) and no escape spells one — and
  # a blank address is none, so neither is drawn.
  def read_addresses
    composite { |tc|
      components = tc.draw(arrays(awkward_text.map { it.delete("\r") }, min_size: 7, max_size: 7)
        .filter { !it.all?(&:empty?) })
      po_box, extended, street, locality, region, postal_code, country = components
      ProTacts::Contact::Address.new(
        po_box:, extended:, street:, locality:, region:, postal_code:, country:,
        label: tc.draw(labels),
        parameters: tc.draw(sampled_from([[], [%w[type pref]]])),
        companions: tc.draw(sampled_from([[], ["X-ABADR:us"]])),
      )
    }
  end

  # The fields a browser could post, read over an added row or a
  # stored one; a row blank throughout is none.
  def form_addresses
    composite { |tc|
      fields = ProTacts::Contact::ADDRESS_COMPONENTS.to_h { [it, tc.draw(awkward_text)] }
      label = tc.draw(labels)
      fields["label"] = label unless label.nil? && tc.draw(booleans)
      over = tc.draw(optional(read_addresses))
      params = over ? {"address" => {"0" => fields}} : {"new_address" => {"0" => fields}}
      ProTacts::Admin::CardForm.addresses([over].compact, params).first
    }.filter { !it.nil? }
  end
end
