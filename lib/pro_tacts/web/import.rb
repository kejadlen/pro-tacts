require "pro_tacts/admin/import_review"
require "pro_tacts/admin/import_upload"
require "pro_tacts/import/land"
require "pro_tacts/import/staged"
require "pro_tacts/import/vcf"

module ProTacts
  class Web < Roda
    # The import screen: a .vcf lands its cards in this server's store
    # (docs/plans/2026-09-21-import-a-vcf.md). It replaces the rake
    # tasks that read Contacts.app on a Mac, built a plan directory,
    # and carried it to a host over HTTP — a .vcf is what every
    # address book on earth already exports, and the machine holding
    # it is whichever one the browser is on.
    #
    # Two requests, because the question this screen exists to ask
    # cannot be asked until the file has been read: the first stages
    # the upload and surveys what is in it, the second spends the
    # answers. The file waits on the server between them
    # (Import::Staged) rather than riding back through the browser.
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
          survey_upload(r)
        end
      end

      # The second half, on its own path rather than the same one: two
      # posts to /import would be told apart by which fields they
      # carried, and a form's fields are the last thing that should
      # decide what a request means.
      r.post "land" do
        land_upload(r)
      end
    end

    private

    # The upload's own POST: the file read and judged whole before
    # anything is staged, `execute`'s old rule that a source which
    # will not read lands nothing. Its answer is the review screen,
    # which is where the decisions are made.
    #: (untyped r) -> String
    def survey_upload(r)
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

      review_screen(
        upload: Import::Staged.write(bytes),
        file: name,
        cards: cards.length,
        unknown: Import::Vcf.unknown(cards),
      )
    end

    # The confirm: the staged file read back, the decisions the review
    # screen collected applied, and the cards landed.
    #
    # The re-read parses a file this already parsed once, on the way to
    # the review screen — not a second judgment of it, but the only way
    # back to the cards, the bytes being what was staged. A file that
    # read then and will not read now is a broken assumption and raises
    # rather than being handled.
    #: (untyped r) -> String
    def land_upload(r)
      id = r.params["upload"].to_s
      bytes = Import::Staged.read(id)
      # Swept out from under a review screen left open overnight, or a
      # confirm submitted twice, the second finding what the first
      # removed. The file is gone either way and only the person has
      # another copy.
      return import_screen(notice: "That upload is no longer here. Choose the file again.") if bytes.nil?

      cards = Import::Vcf.cards(bytes)
      group = r.params["group"].to_s.strip
      landed = Import::Land.call(
        store, cards,
        decisions: decisions_in(r.params["decide"], Import::Vcf.unknown(cards)),
        group: group.empty? ? nil : group,
      )
      Import::Staged.remove(id)

      import_screen(landed:)
    end

    # What the form said to do with each unknown property, read against
    # the survey rather than trusted: the names are the ones this run
    # found, and anything else a post carries is not a property of this
    # file. An answer missing or unrecognized is a keep, the choice
    # that loses nothing.
    #: (untyped param, Array[Import::Vcf::Unknown] unknown) -> Hash[String, String]
    def decisions_in(param, unknown)
      unknown.to_h { |property|
        answer = param.is_a?(Hash) ? param[property.name].to_s : ""
        choice = Import::Vcf::CHOICES.include?(answer) ? answer : Import::Vcf::KEEP
        # A two-element literal is an Array until something says
        # otherwise, and an inline annotation needs its own line.
        [property.name, choice] #: [String, String]
      }
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
    # with. It answers with the result rather than the 303 the other
    # writes answer with, and has to: the staged file is gone, so the
    # re-submission a back button offers has nothing to land, and there
    # is no other page holding what just arrived.
    #: (?landed: Array[Contact]?, ?notice: String?) -> String
    def import_screen(landed: nil, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ImportUpload.call(landed:, notice:)
    end

    #: (upload: String, file: String, cards: Integer, unknown: Array[Import::Vcf::Unknown]) -> String
    def review_screen(upload:, file:, cards:, unknown:)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ImportReview.call(upload:, file:, cards:, unknown:, group: Import::Land.default_group)
    end
  end
end
