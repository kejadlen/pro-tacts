require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/list_item"

module ProTacts
  module Admin
    # The contacts an uploaded .vcf holds, and which of them are in the
    # address book so far (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # A list rather than every card laid open at once: a book is
    # hundreds of contacts and only some of them will have anything
    # worth looking at, so each row says how many of its lines are not
    # coming in and opening one is what shows the pair of cards
    # (Admin::ImportOriginal beside the editor). A row with nothing
    # left behind needs no visit.
    #
    # The import happens a row at a time, on the Save of the screen a
    # row opens, so this is also where the walk is read back: a row
    # that has come in says so and leads to the contact rather than
    # back into the editor. Nothing here writes, which is why there is
    # no "import everything" — the file goes out the way it came in,
    # a contact at a time, and stopping halfway leaves exactly the
    # rows nobody opened.
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
      # @rbs @saved: Hash[String, String]
      # @rbs @notice: String?

      # `rows` is the contact each card will be written as and how
      # many of its original's lines are not coming with it. `upload`
      # is the staged import every link and form carries, `group` the
      # name of the group this import files its arrivals under, and
      # `saved` the contact each row that has come in was written as,
      # by the row's place in the file.
      #: (upload: String, rows: Array[[::ProTacts::Contact, Integer]], unknown: Array[::ProTacts::Import::Vcf::Unknown], group: String, saved: Hash[String, String], ?notice: String?) -> void
      def initialize(upload:, rows:, unknown:, group:, saved:, notice: nil)
        @upload = upload
        @rows = rows
        @unknown = unknown
        @group = group
        @saved = saved
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
            group_field
            finish_form
          end
        end
      end

      # A group made for this import and taking in every contact it
      # brings in, named for the moment by default so one import can
      # be found — or undone — apart from the next. Editable, and
      # emptiable; a name this book already uses joins that group
      # rather than making a second one by the same name
      # (Import::Write#group_id). Which of this book's own groups a
      # contact joins is that contact's question, asked beside its
      # card (Admin::ImportGroups).
      #
      # A field until the first contact comes in, and a fact
      # afterwards: renaming it halfway would leave what is already in
      # the book under the old name and put the rest somewhere else,
      # which is one import in two groups (Web#name_import_group).
      #: () -> void
      def group_field
        if @saved.any?
          p(class: "type-body-sm gl-muted") do
            @group.empty? ? "Coming in with no group of their own." : "Coming in as #{@group}."
          end
          return
        end

        form(action: "/import/#{@upload}/group", method: "post", class: "field-stack") do
          label(class: "field") do
            span(class: "type-label") { "group for the lot" }
            input(type: "text", name: "group", value: @group, placeholder: "no group")
          end
          button(type: "submit") { "name the group" }
        end
      end

      # The way out before the end of the file. An import is a walk,
      # and a walk can be enough: what has come in stays, and what
      # nobody opened is left behind with the copy of the file this
      # was holding.
      #: () -> void
      def finish_form
        form(action: "/import/#{@upload}/done", method: "post", class: "field-stack") do
          p(class: "type-body-sm gl-muted") do
            if @saved.empty?
              "Nothing has come in yet. Open a contact to look it over; its Save is what puts it in the book."
            else
              "#{count(@saved.length, "contact")} in the book. " \
                "Finishing now leaves the other #{@rows.length - @saved.length} behind."
            end
          end
          button(type: "submit", data: {variant: "primary"}) { "finish" }
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
          p(class: "type-body-sm gl-muted") { "Nothing in this file needs reading before it comes in." }
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

      # A row per contact: in the book, or marked where something is
      # being left behind — which is the whole of what the list is
      # for, since those are the rows worth opening.
      #: () -> void
      def contacts_list
        section do
          div(class: "section-head") do
            h2(class: "type-label") { "contacts" }
          end
          ul(class: "card") do
            @rows.each_with_index do |(contact, dropped), index|
              stored = @saved[index.to_s]
              render ListItem.new(
                # A row that has come in leads to the contact it
                # became: the card was written the moment its Save was
                # pressed, and from then on it is edited where every
                # other contact is (Web#open_card).
                href: stored ? "/contacts/#{stored}" : "/import/#{@upload}/#{index}",
                trailing: stored ? "saved" : (count(dropped, "line") + " left behind" if dropped.positive?),
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
