require "pro_tacts/admin/phlex"

module ProTacts
  module Admin
    # Picking groups out of a list too long to read: the filter over
    # the rows, the cap on how many stand shown, the button that lifts
    # it, and the offer to make the group the filter names
    # (docs/plans/2026-09-22-a-few-groups-at-a-time.md).
    #
    # Shared by the two places a contact's groups are picked: the
    # dialog on a stored contact's card (Admin::GroupDialog) and the
    # boxes beside an arriving one (Admin::ImportGroups). A book with
    # three groups and a book with three hundred are the same screen,
    # and the import's is the screen the walk opens once per contact,
    # so the two are the same problem — and a second answer to it
    # would only be a place where they could disagree.
    #
    # Alpine does the filtering, matching each row's lowercased label
    # in `data-label` so no group's name is ever spliced into script.
    # A row it hides still submits its box: hiding is not unticking,
    # and a contact's other groups are not being answered for by a
    # word typed to find one of them. Every row stays in the page for
    # the same reason the plan gives — the filter is client-side, so a
    # row the server left out is a row nothing here can reach.
    class GroupFilter < Phlex::HTML
      # How many rows a list opens with. The dialog is a popover and
      # cannot scroll past its own footer (see the plan, and the
      # scroller admin.css gives it); the import's list is on an
      # ordinary page and caps for the reading rather than the
      # clipping. Enough rows that a household's whole list is there,
      # few enough that a long one still ends in its buttons.
      LIMIT = 8 #: Integer

      # `needle` is the filter as the rows are matched against it, one
      # definition for the three readers of it. `visible` is what the
      # cap adds to `shows`: a capped row joins the list once the
      # filter is typed into or the whole list is asked for, and a
      # filter is the one of the two that can reach a single group
      # without the rest.
      STATE = "{ filter: '', all: false, " \
              "get needle() { return this.filter.trim().toLowerCase() }, " \
              "get labels() { return [...this.$refs.options.querySelectorAll('[data-label]')]" \
              ".map(row => row.dataset.label) }, " \
              "shows(label) { return label.includes(this.needle) }, " \
              "visible(row) { return this.shows(row.dataset.label) && " \
              "(this.all || this.needle !== '' || !('capped' in row.dataset)) }, " \
              "get none() { return !this.labels.some(label => this.shows(label)) }, " \
              "get creatable() { return this.needle !== '' && !this.labels.includes(this.needle) } }" #: String

      # What a filterable row wears: the label to match on, read off
      # the element rather than out of a closure, whether the cap holds
      # it back, and the hiding the two of them drive. Every row the
      # filter is meant to see carries it — a group this book has, and
      # a name an import is about to make — because `creatable` is
      # "none of these", and a row the filter cannot see is a row it
      # would offer to create twice.
      #: (String label, ?capped: bool) -> Hash[untyped, untyped]
      def self.row(label, capped: false)
        {data: {label: label.downcase, capped:}, ":hidden": "!visible($el)"}
      end

      # Which of `ids` the cap holds back, in the order they render.
      # A row already ticked is never capped, however far down the
      # list it sorts: those are the boxes a person opens the list to
      # untick, and one hidden from them makes the list disagree with
      # the screen it was opened from. They take rows from the limit
      # rather than standing outside it, so what stands shown is the
      # limit or the ticked rows, whichever is longer. `shown` is for
      # rows that are always there and are not in `ids` — the names an
      # import is about to make — which take from the limit the same
      # way.
      #: (Array[String] ids, joined: Array[String], ?shown: Integer) -> Array[String]
      def self.capped(ids, joined:, shown: 0)
        ticked, rest = ids.partition { joined.include?(it) }
        rest.drop((LIMIT - ticked.length - shown).clamp(0, LIMIT))
      end

      # @rbs @autofocus: bool
      # @rbs @in_form: bool

      # `autofocus` where the picker is a popover that just opened and
      # nothing else wants the caret; not where it is one field among
      # a card's own.
      #
      # `in_form` where the boxes sit inside a larger form. Enter in a
      # text box submits the form around it, and half a name typed to
      # find a group is not a save. The dialog needs neither the flag
      # nor the guard, its filter standing outside the form it
      # filters, which is the sturdier answer where it is available.
      #: (?autofocus: bool, ?in_form: bool) -> void
      def initialize(autofocus: false, in_form: false)
        @autofocus = autofocus
        @in_form = in_form
      end

      def view_template
        input(type: "search", placeholder: "Filter or add groups",
              aria_label: "Filter or add groups", autofocus: @autofocus,
              x_model: "filter", **enter)
      end

      private

      #: () -> Hash[untyped, untyped]
      def enter
        return {} unless @in_form

        {"@keydown.enter.prevent": "filter = filter.trim()"}
      end

      # The filter itself, offered as a group to make, under the rows
      # it matched none of. Inside the form, being a field of it, and
      # unticked: a filter is as often half a name typed to find a
      # group as it is a new one, and a save must not make "boo" on
      # the way to Booles.
      class Fresh < Phlex::HTML
        def view_template
          template(x_if: "creatable") do
            label do
              input(type: "checkbox", name: "new", ":value": "filter.trim()")
              span(class: "gl-muted", style: "font-style: italic;", x_text: "filter.trim()")
            end
          end
        end
      end

      # What the list says when the filter matches nothing and is not
      # a name either — which, the filter being blank, is also what an
      # empty book says.
      class Empty < Phlex::HTML
        # @rbs @any: bool

        #: (any: bool) -> void
        def initialize(any:)
          @any = any
        end

        def view_template
          template(x_if: "none && !creatable") do
            p(class: "gl-muted") { @any ? "No groups match." : "No groups yet." }
          end
        end
      end

      # The way past the cap for someone who is looking rather than
      # naming: the filter reaches a group already known by name, this
      # reaches the list. It counts the whole list rather than the part
      # under the cap, that being the number a person is deciding
      # whether to read. It stands down while the filter is typed
      # into, which lifts the cap itself.
      #
      # It goes both ways, the label saying which way the next press
      # goes: a list unrolled is the long list the cap exists to
      # avoid, and rolling it back up should not mean closing the
      # screen it is on. The opening label is rendered rather than
      # left to x-text alone, so the button reads before Alpine runs.
      class Rest < Phlex::HTML
        # @rbs @count: Integer

        #: (count: Integer) -> void
        def initialize(count:)
          @count = count
        end

        def view_template
          button(type: "button", data_size: "sm", "x-show": "needle === ''", "@click": "all = !all",
                 x_text: "all ? 'show fewer' : #{label_text.inspect}") { label_text }
        end

        private

        #: () -> String
        def label_text = "show all #{@count} groups"
      end
    end
  end
end
