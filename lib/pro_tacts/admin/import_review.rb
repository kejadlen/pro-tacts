require "pro_tacts/admin/phlex"

require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # The screen an import opens on, and the one it comes back to: what
    # the whole file is losing, what it is coming in under, and the way
    # to stop (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # The contacts themselves are not here. They are the sidebar beside
    # this (Admin::ImportSidebar), which stands on every screen of the
    # walk, so this card is only what is true of the file rather than
    # of any one row in it: which properties are not coming in, and how
    # many lines each of them wears. It is what says whether the list
    # beside it is worth working down at all. That count does not
    # mention the noise a file is losing (Vcf::NOISE): a mark every row
    # wears is a mark that says nothing, and an export's own PRODID is
    # not something anyone is going to copy across by hand.
    #
    # The import happens a row at a time, on the Save of the screen a
    # row opens, so nothing here writes a contact and there is no
    # "import everything". What this does have is the way out before
    # the end of the file — a walk can be enough — and what it costs.
    class ImportReview < Phlex::HTML
      # @rbs @upload: String
      # @rbs @contacts: Integer
      # @rbs @saved: Integer
      # @rbs @unknown: Array[::ProTacts::Import::Vcf::Unknown]
      # @rbs @group: String
      # @rbs @sidebar: Phlex::HTML
      # @rbs @notice: String?

      # `contacts` is how many the file holds and `saved` how many of
      # them are in the book. `upload` is the staged import every link
      # and form carries, `group` the name of the group this import
      # files its arrivals under, and `sidebar` the rows themselves.
      #: (upload: String, contacts: Integer, saved: Integer, unknown: Array[::ProTacts::Import::Vcf::Unknown], group: String, sidebar: Phlex::HTML, ?notice: String?) -> void
      def initialize(upload:, contacts:, saved:, unknown:, group:, sidebar:, notice: nil)
        @upload = upload
        @contacts = contacts
        @saved = saved
        @unknown = unknown
        @group = group
        @sidebar = sidebar
        @notice = notice
      end

      def view_template
        render Layout.new(title: "Import", wide: true, notice: @notice) do
          div(class: "walk") do
            render @sidebar
            div(class: "record") do
              div(class: "record-nav") do
                a(href: "/import", class: "type-label") { "‹ another file" }
              end
              summary_card
            end
          end
        end
      end

      private

      #: () -> void
      def summary_card
        div(class: "card") do
          div(class: "card-body") do
            h1(class: "type-h2", style: "margin: 0;") { count(@contacts, "contact") }
            losses
            group_line
            finish_form
          end
        end
      end

      # The group made for this import and taking in every contact it
      # brings in, named for the moment it opened so one import can be
      # found — or undone — apart from the next. A fact rather than a
      # field: every Save files its contact under it, so a rename
      # halfway would leave what is already in the book under the old
      # name and put the rest somewhere else, and a rename before that
      # is a name for a thing nobody has seen yet. Which groups a
      # contact actually joins — this one among them, ticked and
      # removable — is asked beside that contact's card
      # (Admin::ImportGroups).
      #: () -> void
      def group_line
        p(class: "type-body-sm gl-muted") do
          @group.empty? ? "Coming in with no group of their own." : "Coming in as #{@group}."
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
            if @saved.zero?
              "Nothing has come in yet. Open a contact to look it over; its Save is what puts it in the book."
            else
              "#{count(@saved, "contact")} in the book. " \
                "Finishing now leaves the other #{@contacts - @saved} behind."
            end
          end
          button(type: "submit", data: {variant: "primary"}) { "finish" }
        end
      end

      # What the file is losing, by property rather than by line: a
      # reader deciding whether to open any of the rows beside this
      # wants to know it is `X-SOCIALPROFILE` and `PRODID` going, not
      # that eight hundred lines are.
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

      # A count with its noun, the plural spelled out where an "s" on
      # the end will not do it.
      #: (Integer number, String noun, ?String? plural) -> String
      def count(number, noun, plural = nil)
        number == 1 ? "#{number} #{noun}" : "#{number} #{plural || "#{noun}s"}"
      end
    end
  end
end
