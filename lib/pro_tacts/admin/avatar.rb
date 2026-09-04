require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"

module ProTacts
  module Admin
    # A contact's avatar: the card's picture when it carries one a
    # browser can show, the initials otherwise. One component because
    # three views render this slot — the dashboard's rows, the
    # birthdays' rows, the detail header — and they should not disagree
    # about what an avatar is.
    #
    # The picture renders from the photo route rather than the decoded
    # bytes in hand, so the page carries a URL where it would otherwise
    # carry megabytes of base64 (see the route in Web). Alt is empty:
    # the contact's name is adjacent text in every slot, so the image
    # is decoration, not information.
    class Avatar < Phlex::HTML
      # @rbs @contact: Contact
      # @rbs @size: String?

      #: (contact: Contact, ?size: String?) -> void
      def initialize(contact:, size: nil)
        @contact = contact
        @size = size
      end

      def view_template
        if @contact.photo
          img(class: "avatar", src: "/contacts/#{@contact.id}/photo", alt: "", **attributes)
        else
          span(class: "avatar", **attributes) { Format.initials(@contact) }
        end
      end

      private

      #: () -> Hash[untyped, untyped]
      def attributes
        @size ? {data_size: @size} : {}
      end
    end
  end
end
