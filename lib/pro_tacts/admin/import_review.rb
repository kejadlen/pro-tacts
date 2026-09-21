require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
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
    # at all. Neither count mentions the noise a file is losing
    # (Vcf::NOISE): a mark every row wears is a mark that says
    # nothing, and an export's own PRODID is not something anyone is
    # going to copy across by hand.
    class ImportReview < Phlex::HTML
      # @rbs @upload: String
      # @rbs @rows: Array[[::ProTacts::Contact, Integer]]
      # @rbs @unknown: Array[::ProTacts::Import::Vcf::Unknown]
      # @rbs @group: String
      # @rbs @groups: Array[::ProTacts::Store::Group]
      # @rbs @notice: String?

      # `rows` is the contact each card will land as, paired with how
      # many of its original's lines are not coming with it. `upload`
      # is the staged import every link and the confirm carry.
      # `group` is the name the import offers to make; `groups` is
      # every group this book already has, alphabetical because this
      # is a list to find a name in (the groups dialog's own order).
      #: (upload: String, rows: Array[[::ProTacts::Contact, Integer]], unknown: Array[::ProTacts::Import::Vcf::Unknown], group: String, groups: Array[::ProTacts::Store::Group], ?notice: String?) -> void
      def initialize(upload:, rows:, unknown:, group:, groups:, notice: nil)
        @upload = upload
        @rows = rows
        @unknown = unknown
        @group = group
        @groups = groups.sort_by { it.label.downcase }
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
              # A group made for this import, named for the moment by
              # default so one import can be found — or undone — apart
              # from the next. Editable, and emptiable; a name this
              # book already uses joins that group rather than making
              # a second one by the same name (Import::Land#group_id).
              label(class: "field") do
                span(class: "type-label") { "new group" }
                input(type: "text", name: "group", value: @group, placeholder: "no group")
              end
              existing_groups
              button(type: "submit", data: {variant: "primary"}) { "import #{count(@rows.length, "contact")}" }
            end
          end
        end
      end

      # The groups this book already has, every one of them a box the
      # arrivals can join: an import is as often "these are the people
      # from the school list" as it is a batch that only needs finding
      # again, and a name typed into the box above is a name you have
      # to know. Ticked alongside that name rather than instead of it
      # — both are joins, and neither is required.
      #
      # Unchecked to begin with, every time. The import's own group is
      # the default this screen argues for; putting four hundred
      # arrivals somewhere else is a thing to say, not a box to leave
      # as it was found.
      #: () -> void
      def existing_groups
        return if @groups.empty?

        div(class: "field-stack") do
          span(class: "type-label") { "add to" }
          @groups.each do |group|
            label do
              input(type: "checkbox", name: "groups[]", value: group.id)
              render GroupLabel.new(group:)
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
          # Not "every property here is one pro-tacts reads": the
          # noise is not read either (Vcf::NOISE), it is only not
          # worth a sentence. What is true in both cases is that
          # there is nothing in this file to stop over.
          p(class: "type-body-sm gl-muted") { "Nothing in this file needs reading before it lands." }
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
