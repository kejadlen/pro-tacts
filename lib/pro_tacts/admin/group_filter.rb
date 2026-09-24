require "pro_tacts/admin/phlex"

require "pro_tacts/admin/icons"

module ProTacts
  module Admin
    # Picking from a list too long to read: the filter over
    # the rows, the cap on how many stand shown, the button that lifts
    # it, and the offer to make the group the filter names
    # (docs/plans/2026-09-22-a-few-groups-at-a-time.md).
    #
    # Shared by the three places too long a list is picked from:
    # the two where a contact's groups are picked — the dialog on a
    # stored contact's card (Admin::GroupDialog) and the boxes beside
    # an arriving one (Admin::ImportGroups) — and the members screen,
    # where a group's contacts are (Admin::GroupsMembers). A book with
    # three groups and a book with three hundred are the same screen,
    # and the import's is the screen the walk opens once per contact,
    # so the two are the same problem — and a second answer to it
    # would only be a place where they could disagree. The members
    # screen renders the filter, the cap, and the show-all button,
    # and not the offer to make what the filter names: a filter word
    # cannot mint a contact — that is the dashboard's dialog, with
    # its name fields — so its placeholder says nothing about adding,
    # and `named` idles, nothing rendering Fresh to push onto it.
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
      # without the rest. Neither hides a ticked row — a ticked box
      # submits whether or not it can be seen, so a filter that could
      # make one vanish would be hiding a decision rather than
      # narrowing a list — and the tick is read off the checkbox at
      # each evaluation, so a row answers the next filter change
      # already ticked. `rows` is whatever carries `data-label` — a
      # label in the dialog and the import, an li on the members
      # screen, whose label sits inside its row — and is the element
      # list `none` reads: no row visible, which is what "No groups
      # match" claims. `named` is the names a tick on the offer
      # committed to making (Named): `creatable` and `none` read it
      # directly rather than off the rows' `data-label`s, which those
      # two only re-read when the filter changes — a name committed
      # since would be invisible to both until the next keystroke.
      STATE = "{ filter: '', all: false, named: [], " \
              "get needle() { return this.filter.trim().toLowerCase() }, " \
              "get labels() { return [...this.$refs.options.querySelectorAll('[data-label]')]" \
              ".map(row => row.dataset.label) }, " \
              "get rows() { return [...this.$refs.options.querySelectorAll('[data-label]')] }, " \
              "shows(label) { return label.includes(this.needle) }, " \
              "visible(row) { return row.querySelector('input[type=checkbox]').checked || " \
              "(this.shows(row.dataset.label) && " \
              "(this.all || this.needle !== '' || !('capped' in row.dataset))) }, " \
              "get none() { return !this.named.length && " \
              "!this.rows.some(row => this.visible(row)) }, " \
              "get creatable() { return this.needle !== '' && !this.labels.includes(this.needle) && " \
              "!this.named.some(name => name.toLowerCase() === this.needle) } }" #: String

      # What a filterable row wears: the label to match on, read off
      # the element rather than out of a closure, whether the cap holds
      # it back, and the hiding the two of them drive. Every row the
      # filter is meant to see carries it — a group this book has, a
      # name an import is about to make, a contact the book holds —
      # because `creatable` is "none of these", and a row the filter
      # cannot see is a row it would offer to create twice.
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
      # @rbs @placeholder: String

      # `autofocus` where the picker is a popover that just opened and
      # nothing else wants the caret; not where it is one field among
      # a card's own.
      #
      # `in_form` where the boxes sit inside a larger form. Enter in a
      # text box submits the form around it, and half a name typed to
      # find a group is not a save. The dialog needs neither the flag
      # nor the guard, its filter standing outside the form it
      # filters, which is the sturdier answer where it is available.
      #
      # `placeholder` where the list is not groups and the filter
      # cannot offer to make a row of it: the default names the offer,
      # which is the groups' own.
      #: (?autofocus: bool, ?in_form: bool, ?placeholder: String) -> void
      def initialize(autofocus: false, in_form: false, placeholder: "Filter or add groups")
        @autofocus = autofocus
        @in_form = in_form
        @placeholder = placeholder
      end

      def view_template
        # The filter and its clear in one box, so the button can be
        # positioned at the field's end (admin.css). The click empties
        # the state rather than the box alone — `filter` is what the
        # rows, the cap, and the offer all read — and the reveal is
        # CSS on the box, the header search's own (see Layout).
        div(class: "filter") do
          input(type: "search", placeholder: @placeholder,
                aria_label: @placeholder, autofocus: @autofocus,
                x_model: "filter", **enter)
          button(type: "button", class: "icon-button search-clear", data_size: "sm",
                 aria_label: "Clear filter", "@click": "filter = ''") do
            render Icon.new(:x)
          end
        end
      end

      private

      #: () -> Hash[untyped, untyped]
      def enter
        return {} unless @in_form

        {"@keydown.enter.prevent": "filter = filter.trim()"}
      end

      # The filter itself, offered as a group to make, under the rows
      # it matched none of, and unticked: a filter is as often half a
      # name typed to find a group as it is a new one, and a save must
      # not make "boo" on the way to Booles. A tick is the commit
      # rather than a box the save reads: the name stops riding the
      # filter — which clearing would otherwise carry it off on, and
      # so would typing one more letter past the tick — and stands as
      # one of Named's rows instead.
      class Fresh < Phlex::HTML
        def view_template
          template(x_if: "creatable") do
            label do
              input(type: "checkbox",
                    "@change": "if ($event.target.checked) named.push(filter.trim())")
              span(class: "gl-muted", style: "font-style: italic;", x_text: "filter.trim()")
            end
          end
        end
      end

      # The names a tick on Fresh committed, standing rows in the
      # shape the import gives the names a refused save sent back
      # (Admin::ImportGroups): ticked, submitting `named[]`, and
      # independent of the filter — which is the whole difference
      # from the offer, whose row lives on the filter's own text. An
      # untick withdraws the name, back to the offer if the filter
      # still says it. Never capped and never filtered, being ticked
      # — `visible`'s own rule — so the row needs no attrs to say it:
      # a bare label, always standing.
      class Named < Phlex::HTML
        def view_template
          template(x_for: "name in named") do
            label do
              input(type: "checkbox", name: "named[]", ":value": "name", checked: true,
                    "@change": "named = named.filter(n => n !== name)")
              span(class: "gl-muted", style: "font-style: italic;", x_text: "name")
            end
          end
        end
      end

      # What the list says when the filter matches nothing and is not
      # a name either — which, the filter being blank, is also what an
      # empty book says. `offer` where the picker renders Fresh: there
      # the make-it row stands in for the message while the filter
      # names something creatable, and the message is held back for
      # it; where nothing can be made, `none` alone is the message.
      class Empty < Phlex::HTML
        # @rbs @any: bool
        # @rbs @offer: bool
        # @rbs @noun: String

        #: (any: bool, ?offer: bool, ?noun: String) -> void
        def initialize(any:, offer: true, noun: "groups")
          @any = any
          @offer = offer
          @noun = noun
        end

        def view_template
          template(x_if: @offer ? "none && !creatable" : "none") do
            p(class: "gl-muted") { @any ? "No #{@noun} match." : "No #{@noun} yet." }
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
        # @rbs @noun: String

        #: (count: Integer, ?noun: String) -> void
        def initialize(count:, noun: "groups")
          @count = count
          @noun = noun
        end

        def view_template
          button(type: "button", data_size: "sm", "x-show": "needle === ''", "@click": "all = !all",
                 x_text: "all ? 'show fewer' : #{label_text.inspect}") { label_text }
        end

        private

        #: () -> String
        def label_text = "show all #{@count} #{@noun}"
      end
    end
  end
end
