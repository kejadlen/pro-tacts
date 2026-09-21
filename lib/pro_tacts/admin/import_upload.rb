require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/list_item"

module ProTacts
  module Admin
    # GET /import — the screen an address book arrives on, and the page
    # a confirm answers with (docs/plans/2026-09-21-import-a-vcf.md).
    # Until this existed an import meant rake tasks reading Contacts.app
    # on a Mac and carrying a plan to a host over HTTP; now it is the
    # file that Mac already knows how to export.
    #
    # The form takes one .vcf and nothing else. Looking over what is
    # in it needs the file open, so that is the next screen's
    # (ImportReview, and the pair of cards a row there opens).
    #
    # `imported` is the import that just happened, rendered below the
    # form that is still there to run another.
    class ImportUpload < Phlex::HTML
      # @rbs @imported: Array[Contact]?
      # @rbs @notice: String?

      #: (?imported: Array[Contact]?, ?notice: String?) -> void
      def initialize(imported: nil, notice: nil)
        @imported = imported
        @notice = notice
      end

      def view_template
        render Layout.new(title: "Import", notice: @notice) do
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/", class: "type-label") { "‹ contacts" }
            end
            upload_card
            imported_list if @imported
          end
        end
      end

      private

      #: () -> void
      def upload_card
        div(class: "card") do
          div(class: "card-body") do
            h1(class: "type-h2", style: "margin: 0;") { "Import contacts" }
            p(class: "type-body-sm") do
              "Choose a vCard file — Contacts exports one with File, Export, Export vCard. " \
                "The next screen says what is in it before anything is added, including what " \
                "pro-tacts cannot show and will leave behind."
            end
            form(action: "/import", method: "post", enctype: "multipart/form-data", class: "field-stack") do
              label(class: "field") do
                span(class: "type-label") { "vcard file" }
                input(type: "file", name: "vcf", accept: ".vcf,text/vcard")
              end
              button(type: "submit", data: {variant: "primary"}) { "read the file" }
            end
          end
        end
      end

      # What came in, contact by contact, each linked to the record it
      # became — so the next thing to do, reading one or fixing one, is
      # a click away.
      #: () -> void
      def imported_list
        imported = @imported or return

        section do
          div(class: "section-head") do
            h2(class: "type-label") { "imported (#{imported.length})" }
          end
          ul(class: "card") do
            imported.each do |contact|
              render ListItem.new(
                href: "/contacts/#{contact.id}",
                avatar: Avatar.new(contact:, size: "lg"),
              ) do
                div { Format.name_label(contact) }
              end
            end
          end
        end
      end
    end
  end
end
