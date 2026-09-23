require "pro_tacts/admin/phlex"

require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /import — the screen an address book arrives on
    # (docs/plans/2026-09-21-import-a-vcf.md).
    # Until this existed an import meant rake tasks reading Contacts.app
    # on a Mac and carrying a plan to a host over HTTP; now it is the
    # file that Mac already knows how to export.
    #
    # The form takes one .vcf and nothing else. Looking over what is
    # in it needs the file open, so that is the next screen's
    # (ImportReview, over the walk's list of its contacts and the pair
    # of cards a row there opens).
    #
    # Nothing comes back here at the end of a walk. What arrived is
    # the group the import filed it under, a page that lists the same
    # contacts and is still there tomorrow, so the walk ends on that
    # rather than on a copy of it under this form (Web#close_walk).
    class ImportUpload < Phlex::HTML
      # @rbs @notice: String?

      #: (?notice: String?) -> void
      def initialize(notice: nil)
        @notice = notice
      end

      def view_template
        render Layout.new(title: "Import", notice: @notice) do
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/", class: "type-label") { "‹ contacts" }
            end
            upload_card
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
    end
  end
end
