require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/list_item"

module ProTacts
  module Admin
    # GET /import — the screen a plan lands from, and the page its
    # upload answers with (docs/plans/2026-09-20-import-by-upload.md).
    # Until this existed a plan was carried by `rake import:execute`,
    # which had to run somewhere holding the plan on disk, with a host
    # configured to aim at; here the machine holding the plan is
    # whichever one the browser is on, and the host is the one being
    # looked at.
    #
    # PlanUpload rather than Import, which is the module doing the
    # landing: this is the one screen of it, named for what a person
    # does there, the way DeviceSetup is.
    #
    # The form asks for the card files rather than the whole plan
    # directory: a card names the id it lands under in its filename and
    # the groups it joins in its own text, so `cards/` is the whole of
    # what this server needs. `plan.yml` stays the Mac's ledger, for
    # `import:macos:finalize` to read.
    #
    # `arrivals` is the run that just happened, rendered below the form
    # that is still there to run another.
    class PlanUpload < Phlex::HTML
      # @rbs @arrivals: Array[::ProTacts::Import::Land::Arrival]?
      # @rbs @notice: String?

      #: (?arrivals: Array[::ProTacts::Import::Land::Arrival]?, ?notice: String?) -> void
      def initialize(arrivals: nil, notice: nil)
        @arrivals = arrivals
        @notice = notice
      end

      def view_template
        render Layout.new(title: "Import", notice: @notice) do
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/", class: "type-label") { "‹ contacts" }
            end
            upload_card
            arrivals_list if @arrivals
          end
        end
      end

      private

      #: () -> void
      def upload_card
        div(class: "card") do
          div(class: "card-body") do
            h1(class: "type-h2", style: "margin: 0;") { "Import a plan" }
            p(class: "type-body-sm") do
              "Choose every card in a plan's cards directory. Each one lands as the " \
                "contact its file describes, in the groups that file names."
            end
            form(action: "/import", method: "post", enctype: "multipart/form-data", class: "field-stack") do
              label(class: "field") do
                span(class: "type-label") { "cards" }
                input(type: "file", name: "cards[]", multiple: true, accept: ".yml")
              end
              button(type: "submit", data_variant: "primary") { "import" }
            end
          end
        end
      end

      # What the upload did, contact by contact: a row per card, linked
      # to the record it landed as, so the next thing to do — reading
      # one, fixing one — is a click away. A card already here says so
      # rather than being left out: "nothing happened to this one" is
      # the answer a second upload of the same plan is owed.
      #: () -> void
      def arrivals_list
        arrivals = @arrivals or return

        section do
          div(class: "section-head") do
            h2(class: "type-label") { "landed (#{arrivals.count(&:stored)} of #{arrivals.length})" }
          end
          ul(class: "card") do
            arrivals.each do |arrival|
              render ListItem.new(
                href: "/contacts/#{arrival.contact.id}",
                avatar: Avatar.new(contact: arrival.contact, size: "lg"),
                trailing: ("already here" unless arrival.stored),
              ) do
                div { Format.name_label(arrival.contact) }
              end
            end
          end
        end
      end
    end
  end
end
