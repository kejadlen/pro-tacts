require "pro_tacts/admin/phlex"

require "pro_tacts/admin/layout"
require "pro_tacts/import/vcf"

module ProTacts
  module Admin
    # The second screen of an import: what the uploaded file holds, and
    # the one decision it asks the importer to make
    # (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # A card is stored as the card it arrived as, so nothing here is a
    # field-by-field mapping to approve. The only question is about the
    # properties no screen in this address book shows: keep them (they
    # are served back untouched, just invisible here), drop them, or
    # write them under the note where they can at least be read. Keep
    # is checked, because it is the choice that loses nothing.
    #
    # Each property is shown with how many lines wear it and a few real
    # values out of this very file, so the choice is made looking at
    # the book's own data rather than at a property name.
    #
    # `upload` is the staged file (Import::Staged), carried in a hidden
    # field: the bytes stay on the server, and only the ticket to them
    # makes the round trip.
    class ImportReview < Phlex::HTML
      # @rbs @upload: String
      # @rbs @file: String
      # @rbs @cards: Integer
      # @rbs @unknown: Array[::ProTacts::Import::Vcf::Unknown]
      # @rbs @group: String

      # What each choice is called where it is made. The wording says
      # what happens to the line, not what the server does with it: an
      # importer is deciding about their own address book, not about
      # RFC 6352's rule for a property a server does not understand.
      WORDING = {
        ::ProTacts::Import::Vcf::KEEP => "keep it in the card",
        ::ProTacts::Import::Vcf::DROP => "drop it",
        ::ProTacts::Import::Vcf::NOTE => "write it under the note",
      }.freeze #: Hash[String, String]

      #: (upload: String, file: String, cards: Integer, unknown: Array[::ProTacts::Import::Vcf::Unknown], group: String) -> void
      def initialize(upload:, file:, cards:, unknown:, group:)
        @upload = upload
        @file = file
        @cards = cards
        @unknown = unknown
        @group = group
      end

      def view_template
        render Layout.new(title: "Import") do
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/import", class: "type-label") { "‹ another file" }
            end
            div(class: "card") do
              div(class: "card-body") do
                h1(class: "type-h2", style: "margin: 0;") { @file }
                p(class: "type-body-sm") { "#{count(@cards, "contact")}, ready to land." }
                form(action: "/import/land", method: "post", class: "field-stack") do
                  input(type: "hidden", name: "upload", value: @upload)
                  group_field
                  unknown_fields
                  button(type: "submit", data: {variant: "primary"}) { "import #{count(@cards, "contact")}" }
                end
              end
            end
          end
        end
      end

      private

      # The group everything lands in, named for the moment by default
      # so one import can be found — or undone — apart from the next.
      # Editable, and emptiable: a blank name puts the arrivals in
      # nobody's group but everyone's book.
      #: () -> void
      def group_field
        label(class: "field") do
          span(class: "type-label") { "group" }
          input(type: "text", name: "group", value: @group, placeholder: "no group")
        end
      end

      #: () -> void
      def unknown_fields
        if @unknown.empty?
          p(class: "type-body-sm gl-muted") do
            "Every property in this file is one this address book reads. Nothing to decide."
          end
          return
        end

        p(class: "type-body-sm") do
          "#{count(@unknown.length, "property", "properties")} here " \
            "#{@unknown.length == 1 ? "is one" : "are ones"} " \
            "no screen in this address book shows. Kept, they travel with the card and come back out " \
            "of it untouched; they are just not on display anywhere."
        end
        @unknown.each { unknown_field(it) }
      end

      #: (::ProTacts::Import::Vcf::Unknown property) -> void
      def unknown_field(property)
        div(class: "field") do
          span(class: "type-label") { "#{property.name} (#{count(property.count, "line")})" }
          ul(class: "type-body-sm gl-muted", style: "margin: 0; padding-left: 1.25em;") do
            property.examples.each { |example| li { example } }
          end
          div(class: "field-stack", role: "radiogroup", aria_label: property.name) do
            ::ProTacts::Import::Vcf::CHOICES.each do |choice|
              # A label wrapping its own radio is Gloss's Radio.
              label do
                input(type: "radio", name: "decide[#{property.name}]", value: choice,
                      checked: choice == ::ProTacts::Import::Vcf::KEEP)
                span { WORDING.fetch(choice) }
              end
            end
          end
        end
      end

      # A count with its noun, the plural spelled out where an "s" on
      # the end will not do it.
      #: (Integer number, String noun, ?String? plural) -> String
      def count(number, noun, plural = nil)
        number == 1 ? "#{number} #{noun}" : "#{number} #{plural || "#{noun}s"}"
      end
    end
  end
end
