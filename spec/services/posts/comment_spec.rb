# frozen_string_literal: true

require 'rails_helper'

# What: Posts::Comment, the one rule of a comment written through a token: the
#       MCP tool post_comment and POST /api/v1/tickets/:ticket_id/posts.
# Why:  Until REST R3a the rule lived in the MCP tool alone, and REST took every
#       body as HTML without checking its encoding or NUL bytes. The surfaces word
#       a refusal each their own way; what is refused, and what is stored, is
#       decided here once.
RSpec.describe Posts::Comment, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, organisation: organisation, project: project, creator: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation))
    create(:project_permission, user: user, project: project, tickets_access: :read_write)
  end

  after { ActsAsTenant.current_tenant = nil }

  def nbsp = 0xA0.chr(Encoding::UTF_8)
  def em_space = 0x2003.chr(Encoding::UTF_8)
  def invalid_utf8 = 255.chr.force_encoding(Encoding::UTF_8)

  describe '.parse' do
    it 'takes html as the default format' do
      comment = described_class.parse(body: '<p>x</p>')
      expect(comment).not_to be_refused
      expect(comment).not_to be_plain
    end

    it 'takes plain when named' do
      comment = described_class.parse(body: 'x', format: 'plain')
      expect(comment).not_to be_refused
      expect(comment).to be_plain
    end

    refusals = {
      'a null format' => [{ format: nil }, :format_not_string],
      'a numeric format' => [{ format: 1 }, :format_not_string],
      'a boolean format' => [{ format: true }, :format_not_string],
      'a symbol format' => [{ format: :plain }, :format_not_string],
      'a list as format' => [{ format: ['plain'] }, :format_not_string],
      'an unknown format' => [{ format: 'markdown' }, :format_unknown],
      'a format in capitals' => [{ format: 'PLAIN' }, :format_unknown],
      'an empty format' => [{ format: '' }, :format_unknown],
      'invalid UTF-8 in an html body' => [{ body: -> { invalid_utf8 } }, :body_invalid_utf8],
      'invalid UTF-8 in a plain body' => [{ format: 'plain', body: -> { invalid_utf8 } }, :body_invalid_utf8],
      # A binary string is always valid_encoding?: plain reads it as UTF-8.
      'invalid bytes in a binary body' => [{ format: 'plain', body: -> { "a#{255.chr}b".b } }, :body_invalid_utf8],
      'a plain body that does not transcode' => [{ format: 'plain', body: -> { "a#{0x82.chr}".force_encoding(Encoding::SHIFT_JIS) } },
                                                 :body_invalid_utf8],
      # What a plain multipart part can bring past Rails' encoding check, which
      # refuses only bytes invalid in their own charset: a byte its charset has
      # no character for, and a charset Ruby cannot convert at all.
      'a plain body with a byte its charset has no character for' =>
        [{ format: 'plain', body: -> { "a#{0x81.chr}b".force_encoding(Encoding::Windows_1252) } }, :body_invalid_utf8],
      'a plain body in a charset Ruby cannot convert' =>
        [{ format: 'plain', body: -> { 'abc'.dup.force_encoding(Encoding::UTF_7) } }, :body_invalid_utf8],
      'a NUL byte in a plain body' => [{ format: 'plain', body: "a#{0.chr}b" }, :body_nul],
      'an empty plain body' => [{ format: 'plain', body: '' }, :body_empty],
      'a plain body of blank lines' => [{ format: 'plain', body: " \n\t\r\n " }, :body_empty],
      'a plain body of only a no-break space' => [{ format: 'plain', body: -> { nbsp } }, :body_empty],
      'a plain body of only an em space' => [{ format: 'plain', body: -> { em_space } }, :body_empty],
      'an empty html body' => [{ body: '' }, :body_empty],
      'an html body of spaces' => [{ body: "  \n " }, :body_empty],
      'no body' => [{ body: nil }, :body_empty]
    }

    refusals.each do |label, (arguments, refusal)|
      it "refuses #{label} as #{refusal}" do
        arguments = arguments.transform_values { |value| value.is_a?(Proc) ? instance_exec(&value) : value }
        comment = described_class.parse(**{ body: 'Hallo' }.merge(arguments))
        expect(comment).to be_refused
        expect(comment.refusal).to eq(refusal)
      end
    end

    it 'names every refusal it can give in REFUSALS' do
      expect(described_class::REFUSALS).to eq(refusals.values.map(&:last).uniq)
    end

    it 'checks the format before the body' do
      expect(described_class.parse(body: "a#{0.chr}b", format: 'markdown').refusal).to eq(:format_unknown)
    end

    it 'checks the encoding before NUL bytes, so no string method runs on invalid bytes' do
      expect(described_class.parse(body: "#{invalid_utf8}#{0.chr}", format: 'plain').refusal).to eq(:body_invalid_utf8)
    end

    # html keeps what both surfaces always did: the HTML parser drops a NUL byte.
    it 'lets a NUL byte through in an html body' do
      expect(described_class.parse(body: "a#{0.chr}b")).not_to be_refused
    end

    # A multipart part (REST) may name a charset of its own; JSON and forms
    # always give UTF-8.
    it 'keeps an html body in an encoding of its own as it came, for ActionText to read as before' do
      latin1 = "a#{0xE4.chr}b".force_encoding(Encoding::ISO_8859_1)
      expect(described_class.parse(body: latin1)).not_to be_refused
      expect(described_class.parse(body: "a#{0xFF.chr}b".b)).not_to be_refused
    end

    # Kept, not transcoded: the two differ only where a byte has no character
    # in its charset (0x81 in Windows-1252). Transcoding would refuse it here;
    # ActionText fails the save instead, as it did before R3a.
    it 'keeps an html body in a named encoding even where it would not transcode' do
      cp1252 = "a#{0x81.chr}b".force_encoding(Encoding::CP1252)
      expect(described_class.parse(body: cp1252)).not_to be_refused
    end

    # html takes a no-break space as text, as it always did; the model then
    # decides on the stored plain text.
    it 'leaves an html body of a no-break space to the model' do
      expect(described_class.parse(body: nbsp)).not_to be_refused
    end
  end

  describe '#build' do
    def build(**arguments)
      described_class.parse(**arguments).build(ticket: ticket, current_user: user)
    end

    it 'builds the unsaved post through Actors::SavePost, the web form write' do
      expect(Actors::SavePost).to receive(:new)
        .with(ticket: ticket, current_user: user, params: { content: '<p>x</p>', is_private: false, visible_to_user_id: nil })
        .and_call_original
      post = build(body: '<p>x</p>')
      expect(post).to be_a(Post).and be_new_record
      expect(post.ticket).to eq(ticket)
    end

    it 'stores an html body as sent' do
      body = '<p><b>bold</b> &lt;tag&gt;</p>'
      expect(build(body: body).content.body.to_html).to eq(body)
    end

    it 'converts a plain body through Posts::PlainTextBody' do
      body = "Zeile 1\r\nZeile 2\n\nAbsatz <b>&"
      expect(Posts::PlainTextBody).to receive(:call).with(body: body).and_call_original
      expect(build(body: body, format: 'plain').content.body.to_html)
        .to eq('<p>Zeile 1<br>Zeile 2</p><p>Absatz &lt;b&gt;&amp;</p>')
    end

    it 'transcodes a plain body in an encoding of its own to UTF-8' do
      latin1 = "a#{0xE4.chr}<b".force_encoding(Encoding::ISO_8859_1)
      expect(build(body: latin1, format: 'plain').content.body.to_html).to eq("<p>a#{0xE4.chr(Encoding::UTF_8)}&lt;b</p>")
    end

    it 'reads a plain body in binary as UTF-8' do
      binary = "a#{0xC3.chr}#{0xA4.chr}b".b
      expect(build(body: binary, format: 'plain').content.body.to_html).to eq("<p>a#{0xE4.chr(Encoding::UTF_8)}b</p>")
    end

    it 'hands an html body in an encoding of its own to ActionText as it came' do
      latin1 = "<p>a#{0xE4.chr}b</p>".force_encoding(Encoding::ISO_8859_1)
      expect(build(body: latin1).content.body.to_html).to eq("<p>a#{0xE4.chr(Encoding::UTF_8)}b</p>")
    end

    it 'escapes markup in a plain body, so it lands as text' do
      post = build(body: '<script>alert(1)</script><img src=x onerror=alert(2)>&amp;', format: 'plain')
      html = post.content.body.to_html
      expect(html).not_to include('<script', '<img')
      expect(html).to include('&lt;script&gt;', '&lt;img', '&amp;amp;')
    end

    it 'takes a body that is no string as its text, as both surfaces always did' do
      expect(build(body: true).content.body.to_html).to eq('true')
      expect(build(body: 12, format: 'plain').content.body.to_html).to eq('<p>12</p>')
    end

    { true => true, 'true' => true, false => false, 'false' => false, '1' => false, 1 => false, nil => false }
      .each do |given, stored|
        it "reads is_private #{given.inspect} as #{stored}" do
          expect(build(body: 'x', is_private: given).is_private).to be(stored)
        end
      end

    it 'passes the addressee on to the model, which checks it' do
      expect(build(body: 'x', is_private: true, visible_to_user_id: user.id).visible_to_user_id).to eq(user.id)
    end

    it 'builds an empty body, which the model refuses on save' do
      comment = described_class.parse(body: '')
      expect(comment.build(ticket: ticket, current_user: user).content).to be_blank
      expect { expect(comment.save.code).to eq(:validation_failed) }.not_to change(Post, :count)
    end

    %i[format_not_string format_unknown body_invalid_utf8 body_nul].each do |refusal|
      it "refuses to build a comment it could not read (#{refusal})" do
        arguments = {
          format_not_string: { body: 'x', format: 1 }, format_unknown: { body: 'x', format: 'markdown' },
          body_invalid_utf8: { body: invalid_utf8 }, body_nul: { body: "a#{0.chr}b", format: 'plain' }
        }.fetch(refusal)
        expect { build(**arguments) }.to raise_error(ArgumentError, /#{refusal}/)
      end
    end
  end

  describe '#save' do
    it 'writes the post and its post_added activity through the actor' do
      comment = described_class.parse(body: "Erste Zeile\nzweite", format: 'plain')
      post = comment.build(ticket: ticket, current_user: user)

      result = nil
      expect { result = comment.save }.to change(Post, :count).by(1)
      expect(result).to be_success
      expect(post).to be_persisted
      expect(post.user).to eq(user)
      expect(post.plain_text_version).to eq("Erste Zeile\nzweite")
      expect(Activity.find_by(action: 'post_added', secondary: post)).to be_present
    end

    it 'answers the model refusal of an html body without text, writing nothing' do
      comment = described_class.parse(body: '<p></p>')
      comment.build(ticket: ticket, current_user: user)

      result = nil
      expect { result = comment.save }.not_to change(Post, :count)
      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
    end

    it 'refuses to save a comment that was not built' do
      expect { described_class.parse(body: 'x').save }.to raise_error(ArgumentError)
    end

    # BaseActor answers an unexpected exception as :internal_error only where it
    # does not re-raise (production); development and test re-raise.
    def without_reraise
      original = Rails.application.config.x.actors.reraise_unexpected
      Rails.application.config.x.actors.reraise_unexpected = false
      yield
    ensure
      Rails.application.config.x.actors.reraise_unexpected = original
    end

    # The author's subscription runs after the commit (Post after_create_commit).
    it 'counts a comment written before a failure after the commit as saved' do
      comment = described_class.parse(body: 'x', format: 'plain')
      post = comment.build(ticket: ticket, current_user: user)
      allow(NotificationSubscription).to receive(:system_subscribe).and_raise(ActiveRecord::ConnectionNotEstablished, 'gone')

      result = nil
      expect { without_reraise { result = comment.save } }.to change(Post, :count).by(1)
      expect(result).to be_success
      expect(result.resource).to eq(post)
    end

    # The post_added activity is written inside the transaction: a failure there
    # rolls the post back, and it must not count as saved.
    it 'answers a failure before the commit as a failure, writing nothing' do
      comment = described_class.parse(body: 'x', format: 'plain')
      post = comment.build(ticket: ticket, current_user: user)
      allow_any_instance_of(Ticket).to receive(:track_post_added).and_raise(ActiveRecord::ConnectionNotEstablished, 'gone')

      result = nil
      expect { without_reraise { result = comment.save } }.not_to change(Post, :count)
      expect(result).not_to be_success
      expect(result.code).to eq(:internal_error)
      expect(post).not_to be_persisted
    end
  end
end
