require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"

module ProTacts
  module Admin
    # The dashboard's ambient column: who has a birthday soon, in the
    # order they arrive, each row opening the contact's card. The
    # store's query has already decided the hard parts (arrival order,
    # the year wrap, which partial shapes land on a day at all); this
    # renders what it hands back, and a birthday without a year shows
    # its day without an age.
    class UpcomingBirthdays < Phlex::HTML
      LIMIT = 10

      #: (upcoming: Array[Store::UpcomingBirthday]) -> void
      def initialize(upcoming:)
        @upcoming = upcoming
      end

      def view_template
        section do
          h2(class: "type-label") { "upcoming birthdays" }
          if @upcoming.empty?
            p(class: "type-body-sm") { "No birthdays to show." }
          else
            ul(class: "card") { @upcoming.each { render_row(it) } }
          end
        end
      end

      private

      #: (Store::UpcomingBirthday upcoming) -> void
      def render_row(upcoming)
        contact = upcoming.contact
        li do
          a(href: "/contacts/#{contact.id}") do
            render Avatar.new(contact: contact)
            div(style: "flex: 1; min-width: 0;") do
              div(style: "font-weight: 550;") { contact.name || contact.id }
              div(class: "type-body-sm") { date_line(upcoming) }
            end
            span(class: "type-label") { Format.time_until(upcoming.occurs_on) }
          end
        end
      end

      # The birthday as the contact's own card shows it, with the age
      # it turns on the day when the year is there to know it from.
      #: (Store::UpcomingBirthday upcoming) -> String
      def date_line(upcoming)
        birthday = upcoming.contact.birthday
        text = Format.birthday(upcoming.contact).to_s
        return text if birthday.nil? || birthday.year.nil?

        "#{text} (turns #{upcoming.occurs_on.year - birthday.year})"
      end
    end
  end
end
