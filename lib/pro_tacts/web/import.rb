require "pro_tacts/admin/card_form"
require "pro_tacts/admin/contacts_edit"
require "pro_tacts/admin/import_original"
require "pro_tacts/admin/import_review"
require "pro_tacts/admin/import_upload"
require "pro_tacts/birthday"
require "pro_tacts/import/land"
require "pro_tacts/import/staged"
require "pro_tacts/import/vcf"

module ProTacts
  class Web < Roda
    # The import screens: a .vcf, read, looked over contact by
    # contact, and landed (docs/plans/2026-09-21-import-a-vcf.md).
    # They replace the rake tasks that read Contacts.app on a Mac,
    # built a plan directory, and carried it to a host over HTTP — a
    # .vcf is what every address book on earth already exports, and
    # the machine holding it is whichever one the browser is on.
    #
    # Four screens, because an import is a walk rather than a
    # submission: choose the file, look down the contacts it holds,
    # open any of them beside the card it arrived as, and confirm.
    # What the walk reads and writes waits on the server between them
    # (Import::Staged); nothing is in the store until the confirm.
    #
    # Under the same identity gate as every other route (web.rb),
    # which is also where the arrivals' books come from: a card this
    # creates joins everyone's book the way a client's create does, so
    # the person importing does not have to be the person syncing.
    hash_branch("import") do |r|
      r.is do
        r.get do
          import_screen
        end

        r.post do
          stage_upload(r)
        end
      end

      r.on String do |upload|
        # Before the index below, and distinguishable from one: a
        # path segment is what says which request this is, not which
        # fields a form happened to carry.
        r.post "land" do
          land_upload(r, upload)
        end

        r.is do
          r.get do
            review_screen(upload)
          end
        end

        # The contact's place in the file is its name here. There is
        # no minted id until it lands, and the file's own order is
        # the one thing about a card that cannot change under the
        # walk: the editor's save rewrites a card in place and never
        # adds or removes one.
        r.on Integer do |index|
          r.is do
            r.get do
              card_screen(upload, index)
            end

            r.post do
              save_card(r, upload, index)
            end
          end
        end
      end
    end

    private

    # The upload's own POST: the file read and judged whole before
    # anything is staged, the old `execute`'s rule that a source which
    # will not read lands nothing. What it stages is both readings —
    # the file as it arrived, and the cards pared to what this book
    # shows — and then it is the review screen's walk.
    #: (untyped r) -> untyped
    def stage_upload(r)
      upload = file_in(r.params["vcf"])
      return import_screen(notice: "Choose a .vcf file to import.") if upload.nil?

      name = File.basename(upload[:filename].to_s)
      # Relabelled and judged in the same breath, Web#write_card's rule
      # for the one other body this app reads: a multipart part arrives
      # as binary, and a force_encoding nobody validates is a lie every
      # later reader inherits.
      bytes = upload.fetch(:tempfile).read.force_encoding(Encoding::UTF_8)
      return import_screen(notice: "#{name} is not UTF-8 text.") unless bytes.valid_encoding?

      begin
        cards = Import::Vcf.cards(bytes)
      rescue Import::Vcf::Invalid => error
        return import_screen(notice: error.message)
      end

      id = Import::Staged.open(
        original: bytes,
        landing: joined(cards.map { Import::Vcf.read(it).card }),
      )
      # A 303, the other writes' answer, because what follows is a
      # walk: every screen of it is a GET a back button can revisit.
      r.redirect "/import/#{id}", 303
    end

    # The contacts the file holds, each with what it is losing.
    #: (String upload, ?notice: String?) -> String
    def review_screen(upload, notice: nil)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      originals, landing = staged
      rows = landing.each_with_index.map { |card, index|
        # A two-element literal is an Array until something says
        # otherwise, and an inline annotation needs its own line.
        dropped = Import::Vcf.read(originals.fetch(index)).dropped
        [import_contact(card, index), Import::Vcf.losses(dropped).length] #: [Contact, Integer]
      }

      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ImportReview.call(
        upload:,
        rows:,
        unknown: Import::Vcf.unknown(originals),
        group: Import::Land.default_group,
        notice:,
      )
    end

    # One contact, the card it arrived as beside the card that is
    # landing. The right-hand half is the contact editor itself, not a
    # copy of it: a field the two disagreed about would be a field an
    # import writes and an edit cannot undo.
    #: (String upload, Integer index, ?notice: String?) -> String?
    def card_screen(upload, index, notice: nil)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      originals, landing = staged
      original = originals[index]
      card = landing[index]
      # An index past the end of the file is the empty-body 404 the
      # not_found handler fills in, the same as a contact id nobody
      # has.
      return nil if original.nil? || card.nil?

      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ContactsEdit.call(
        contact: import_contact(card, index),
        notice:,
        action: "/import/#{upload}/#{index}",
        back: ["/import/#{upload}", "the import"],
        aside: Admin::ImportOriginal.new(card: original, dropped: Import::Vcf.read(original).dropped),
      )
    end

    # The editor's save, written back into the import rather than into
    # the store: #apply_edit's shape over a card that is not a contact
    # yet, down to the refusals, because it is the same form.
    #: (untyped r, String upload, Integer index) -> untyped
    def save_card(r, upload, index)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      _originals, landing = staged
      card = landing[index]
      return nil if card.nil?

      contact = import_contact(card, index)

      # N and FN are mandatory (RFC 2426 section 4), so a save blank
      # throughout is refused — the toast is the backstop, the form's
      # name pair (Admin::NamePair) being the browser's own refusal of
      # the same.
      first = r.params["first"].to_s.strip
      middle = r.params["middle"].to_s.strip
      last = r.params["last"].to_s.strip
      return card_screen(upload, index, notice: "A contact needs a name.") if first.empty? && last.empty?

      fields = r.params["birthday"]
      birthday =
        if fields.is_a?(Hash)
          begin
            Admin::CardForm.birthday(fields)
          rescue ArgumentError
            return card_screen(upload, index, notice: "That birthday is not a shape a date can take.")
          end
        else
          contact.birthday
        end

      # The snapshot guard the editor always carries, over the staged
      # card rather than a stored one: two tabs open on the same
      # import are the case, and applying this save over the other
      # one's would revert it.
      if r.params["etag"].to_s != contact.etag
        return card_screen(upload, index, notice: "This card changed since the page loaded; nothing was saved.")
      end

      edited = Admin::CardForm.contact_card(contact, first, middle, last, r.params)
      # The birthday goes back into the card, an import having no
      # model to hold one until it lands. Skipped for a card carrying
      # a BDAY spelling the model does not read: that line stayed in
      # the card (#import_contact, Store#put's own rule), no row
      # rendered for it, and a replace here would delete it.
      unless carries_own_bday?(contact)
        line = birthday&.to_line
        # A birthday with no wire form — a year on its own, a month
        # without its day — is one a vCard 3.0 card cannot spell
        # (docs/plans/2026-08-31-partial-birthdays.md). A stored
        # contact keeps one in the model and serves a card without it;
        # a staged contact has no model, so the card is the whole of
        # what it is, and writing it without the date would lose the
        # date the moment it was typed. Say so instead.
        if birthday && line.nil?
          return card_screen(upload, index, notice: "A card cannot hold a birthday that partial until it lands. Land the contact, then add it on its own page.")
        end

        edited = edited.replace("BDAY", line ? [line] : [])
      end

      landing[index] = edited
      Import::Staged.update(upload, joined(landing))
      r.redirect "/import/#{upload}", 303
    end

    # The confirm: the cards as the walk left them, landed.
    #: (untyped r, String upload) -> String
    def land_upload(r, upload)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      _originals, landing = staged
      group = r.params["group"].to_s.strip
      landed = Import::Land.call(store, landing, group: group.empty? ? nil : group)
      Import::Staged.close(upload)

      import_screen(landed:)
    end

    # The import's two readings, or none when it is gone — swept out
    # from under a screen left open overnight, or landed already, a
    # second confirm finding what the first removed. Ordinary enough
    # for the screen to say so and ask for the file again.
    #
    # The re-read parses files this already parsed, which is not a
    # second judgment of them: the bytes are what was staged, and this
    # is the only way back to the cards. A file that read on the way
    # in and will not read now is a broken assumption and raises.
    #: (String upload) -> [Array[VCard], Array[VCard]]?
    def staged_cards(upload)
      original = Import::Staged.read(upload, Import::Staged::ORIGINAL)
      landing = Import::Staged.read(upload, Import::Staged::LANDING)
      return nil if original.nil? || landing.nil?

      [Import::Vcf.cards(original), Import::Vcf.cards(landing)]
    end

    # A staged card read as the contact the editor edits. The id is
    # its place in the file, there being no minted one until it lands,
    # and no group lends an unlanded card a line.
    #
    # The birthday comes out of the card and into the model, which is
    # the split Store#put makes on the way in
    # (docs/plans/2026-09-11-every-birthday-in-the-model.md) — made
    # here too, so the editor renders the same row over an import as
    # over a contact. A BDAY the model does not read stays in the
    # card, that method's own rule.
    #: (VCard card, Integer index) -> Contact
    def import_contact(card, index)
      bdays, rest = card.extract("BDAY")
      birthday = bdays.filter_map { it.property }.filter_map { Birthday.from_property(it) }.first
      Contact.new(id: index.to_s, stored: birthday ? rest : card, birthday:, inherited: [])
    end

    #: (Contact contact) -> bool
    def carries_own_bday?(contact)
      contact.stored.lines.any? { it.names?("BDAY") }
    end

    # Cards back into a file, each keeping its own bytes. A break
    # after any that did not carry one: a file whose last card ends
    # without a newline is still a file, and two cards glued at
    # END:VCARDBEGIN:VCARD is not.
    #: (Array[VCard] cards) -> String
    def joined(cards)
      cards.map { |card|
        bytes = card.to_s
        bytes.end_with?("\n") ? bytes : "#{bytes}\r\n"
      }.join
    end

    # The file part the form sent, and none for a POST carrying no
    # file: #ids_in's shape over an upload, and its reason for being a
    # method — the empty case needs a type, and the signature is where
    # one fits.
    #: (untyped param) -> untyped
    def file_in(param)
      param if param.is_a?(Hash) && param[:tempfile]
    end

    # The screen a file is chosen on, and the page a landing answers
    # with. The landing answers with the result rather than a 303, and
    # has to: the staged import is gone, so the re-submission a back
    # button offers has nothing to land, and there is no other page
    # holding what just arrived.
    #: (?landed: Array[Contact]?, ?notice: String?) -> String
    def import_screen(landed: nil, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ImportUpload.call(landed:, notice:)
    end

    #: () -> String
    def expired_screen
      import_screen(notice: "That import is no longer here. Choose the file again.")
    end
  end
end
