require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/list_item"

module ProTacts
  module Admin
    # The contacts an uploaded .vcf holds, before any of them land
    # (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # A list rather than every card laid open at once: a book is
    # hundreds of contacts and only some of them will have anything
    # worth looking at, so each row says how many of its lines are not
    # coming in and opening one is what shows the pair of cards
    # (Admin::ImportOriginal beside the editor). A row with nothing
    # left behind needs no visit.
    #
    # Above the list, the same fact for the whole file: which
    # properties are not coming in, and how many lines each of them
    # wears. It is what says whether the list is worth working down
    # at all — a file losing nothing but PRODID can be landed unread.
    class ImportReview < Phlex::HTML
      # @rbs @upload: String
      # @rbs @rows: Array[[::ProTacts::Contact, Integer]]
      # @rbs @unknown: Array[::ProTacts::Import::Vcf::Unknown]
      # @rbs @group: String
      # @rbs @notice: String?

      # `rows` is the contact each card will land as, paired with how
      # many of its original's lines are not coming with it. `upload`
      # is the staged import every link and the confirm carry.
      #: (upload: String, rows: Array[[::ProTacts::Contact, Integer]], unknown: Array[::ProTacts::Import::Vcf::Unknown], group: String, ?notice: String?) -> void
      def initialize(upload:, rows:, unknown:, group:, notice: nil)
        @upload = upload
        @rows = rows
        @unknown = unknown
        @group = group
        @notice = notice
      end

      def view_template
        render Layout.new(title: "Import", notice: @notice) do
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/import", class: "type-label") { "‹ another file" }
            end
            summary_card
            contacts_list
          end
        end
      end

      private

      #: () -> void
      def summary_card
        div(class: "card") do
          div(class: "card-body") do
            h1(class: "type-h2", style: "margin: 0;") { count(@rows.length, "contact") }
            losses
            form(action: "/import/#{@upload}/land", method: "post", class: "field-stack") do
              # The group everything lands in, named for the moment by
              # default so one import can be found — or undone — apart
              # from the next. Editable, and emptiable: a blank name
              # puts the arrivals in nobody's group but everyone's book.
              label(class: "field") do
                span(class: "type-label") { "group" }
                input(type: "text", name: "group", value: @group, placeholder: "no group")
              end
              button(type: "submit", data: {variant: "primary"}) { "import #{count(@rows.length, "contact")}" }
            end
          end
        end
      end

      # What the file is losing, by property rather than by line: a
      # reader deciding whether to open any of the rows below wants to
      # know it is `X-SOCIALPROFILE` and `PRODID` going, not that
      # eight hundred lines are.
      #: () -> void
      def losses
        if @unknown.empty?
          p(class: "type-body-sm gl-muted") { "Every property in this file is one pro-tacts reads." }
          return
        end

        p(class: "type-body-sm") do
          plain "No screen in pro-tacts shows "
          plain @unknown.length == 1 ? "this property" : "these properties"
          plain ", so they stay behind. Open a contact to read what its own card says and "
          plain "copy across anything worth keeping."
        end
        ul(class: "card-lines") do
          @unknown.each do |property|
            li do
              span { property.name }
              span(class: "type-label") { count(property.count, "line") }
            end
          end
        end
      end

      # A row per contact, marked where something is being left
      # behind — which is the whole of what the list is for, since
      # those are the rows worth opening.
      #: () -> void
      def contacts_list
        section do
          div(class: "section-head") do
            h2(class: "type-label") { "contacts" }
          end
          ul(class: "card") do
            @rows.each_with_index do |(contact, dropped), index|
              render ListItem.new(
                href: "/import/#{@upload}/#{index}",
                trailing: (count(dropped, "line") + " left behind" if dropped.positive?),
              ) do
                div { Format.name_label(contact) }
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
