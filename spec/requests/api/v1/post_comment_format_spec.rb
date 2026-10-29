# frozen_string_literal: true

require 'rails_helper'

# What: POST /api/v1/tickets/:ticket_id/posts writes by the rule the MCP tool
#       post_comment writes by (Posts::Comment, cli_rest_plan R3 a): post[format]
#       html (the default, the body stored as sent) or plain (literal text).
# Type: Request spec.
# Why:  The terminal client comments over REST and sends literal text, never
#       HTML it built itself. Before R3a REST took every body as HTML and checked
#       neither its encoding nor NUL bytes. Pinned here: plain letting markup
#       through, a NUL reaching the database, an input refusal telling a hidden
#       ticket from a missing one, a private comment reaching people it is not
#       for, the side effects of the web form missing, a replay writing twice,
#       the answer without format changing, an exception text reaching the client.
RSpec.describe 'API V1 comment format', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, language_preference: 'en') }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation, creator: user) }
  end
  let(:read_only) { false }
  let(:pat) do
    build(:personal_access_token, user: user, organisations: [organisation], read_only: read_only).tap do |token|
      token.token_hash = nil
      token.token_prefix = nil
      token.generate_token!
    end
  end
  let!(:permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
    end
  end

  def headers(key: nil, json: false)
    { 'Authorization' => "Bearer #{pat.token}" }.tap do |h|
      h['Idempotency-Key'] = key if key
      h['Content-Type'] = 'application/json' if json
    end
  end

  # Form-encoded, as most callers send it.
  def comment(ticket_id: ticket.id, key: nil, **fields)
    post "/api/v1/tickets/#{ticket_id}/posts", params: { post: fields }, headers: headers(key: key)
  end

  # JSON, for values a form cannot carry (numbers, booleans, null, lists).
  def comment_json(fields, ticket_id: ticket.id)
    post "/api/v1/tickets/#{ticket_id}/posts", params: { post: fields }.to_json, headers: headers(json: true)
  end

  # Multipart, where a text part may name a charset of its own (Rack tags the
  # string with it); JSON and forms always arrive as UTF-8.
  def comment_multipart(parts)
    boundary = 'r3a-boundary'
    raw = ''.b
    parts.each do |name, (type, bytes)|
      raw << "--#{boundary}\r\nContent-Disposition: form-data; name=\"post[#{name}]\"\r\n".b
      raw << "Content-Type: #{type}\r\n".b if type
      raw << "\r\n".b << bytes.b << "\r\n".b
    end
    raw << "--#{boundary}--\r\n".b
    post "/api/v1/tickets/#{ticket.id}/posts", params: raw,
                                               headers: headers.merge('Content-Type' => "multipart/form-data; boundary=#{boundary}")
  end

  def body = response.parsed_body

  def posts_count = ActsAsTenant.without_tenant { Post.count }

  def saved = ActsAsTenant.without_tenant { Post.find(body.dig('data', 'id')) }

  # Written out, not read through I18n.t as the controller reads them: a missing
  # or misspelt key would be compared with itself, and an English key that is
  # missing falls back to the German text on both sides.
  def refusal(key, locale: :en)
    text = {
      en: {
        format_not_string: 'Give the format (post[format]) as text: html or plain.',
        format_unknown: 'The format (post[format]) must be html or plain.',
        body_invalid_utf8: 'The comment (post[body]) cannot be read as UTF-8.',
        body_nul: 'A plain comment (post[body]) must not contain NUL bytes.',
        body_empty: 'The comment (post[body]) has no text.'
      },
      de: { format_unknown: 'Das Format (post[format]) muss html oder plain sein.' }
    }.fetch(locale).fetch(key)
    { 'error' => 'validation_failed', 'code' => 'invalid_input', 'errors' => [text] }
  end

  def nbsp = 0xA0.chr(Encoding::UTF_8)

  describe 'format plain' do
    let(:text) { "Zeile 1\nZeile 2\n\nAbsatz <b>&" }

    it 'stores literal text: paragraphs, line breaks and escaped markup' do
      expect { comment(format: 'plain', body: text) }.to change { posts_count }.by(1)
      expect(response).to have_http_status(:created)
      expect(body.dig('data', 'body_text')).to eq(text)
      expect(body.dig('data', 'body_html')).to eq('<p>Zeile 1<br>Zeile 2</p><p>Absatz &lt;b&gt;&amp;</p>')
      expect(saved.plain_text_version).to eq(text)
    end

    it 'takes CRLF as LF and drops blank lines at the edges' do
      comment(format: 'plain', body: "\r\n \r\nZeile 1\r\nZeile 2\r\n\r\n")
      expect(body.dig('data', 'body_text')).to eq("Zeile 1\nZeile 2")
      expect(body.dig('data', 'body_html')).to eq('<p>Zeile 1<br>Zeile 2</p>')
    end

    {
      'a script' => '<script>alert(1)</script>',
      'an image with a handler' => '<img src=x onerror=alert(1)>',
      'entities' => '&lt;tag&gt; &amp; &#60;b&#62;',
      'operators' => 'a < b && c > d'
    }.each do |label, text|
      it "lands #{label} as text, never as markup" do
        comment(format: 'plain', body: text)
        expect(response).to have_http_status(:created)
        expect(body.dig('data', 'body_text')).to eq(text)
        fragment = Nokogiri::HTML.fragment(body.dig('data', 'body_html'))
        expect(fragment.css('*').map(&:name).uniq).to eq(['p'])
        expect(fragment.text).to eq(text)
      end
    end

    it 'answers the fields the endpoint always answered' do
      comment(format: 'plain', body: 'x')
      expect(body['data'].keys).to eq(%w[id ticket_id author body_html body_text is_private visible_to_user_id created_at updated_at])
    end

    # Otherwise every comment the client sends logs format as an unpermitted
    # parameter; the rule reads the raw value either way.
    it 'does not report format as an unpermitted parameter' do
      unpermitted = []
      collect = ->(*, payload) { unpermitted.concat(payload[:keys]) }
      ActiveSupport::Notifications.subscribed(collect, 'unpermitted_parameters.action_controller') do
        comment(format: 'plain', body: 'x')
      end
      expect(response).to have_http_status(:created)
      expect(unpermitted).to be_empty
    end
  end

  # Existing callers (gboyke/lalabase-mcp among them) send no format. Their
  # answer stays byte for byte, refusals and their order included; the contract
  # recorded it before R3a (rest > POST /api/v1/tickets/:ticket_id/posts).
  describe 'without format, as before R3a' do
    it 'stores the body as sent and answers in the old shape, byte for byte' do
      html = '<p><b>fett</b> &amp; mehr</p>'
      comment(body: html)
      expect(response).to have_http_status(:created)
      post_record = saved
      expected = { data: { id: post_record.id, ticket_id: ticket.id, author: { id: user.id, name: user.display_name },
                           body_html: html, body_text: 'fett & mehr', is_private: false, visible_to_user_id: nil,
                           created_at: post_record.created_at.iso8601, updated_at: post_record.updated_at.iso8601 } }
      expect(response.body).to eq(expected.to_json)
    end

    it 'answers format html exactly like no format' do
      comment(body: '<p>Gleich</p>')
      without = body['data'].except('id', 'created_at', 'updated_at')
      comment(format: 'html', body: '<p>Gleich</p>')
      expect(body['data'].except('id', 'created_at', 'updated_at')).to eq(without)
    end

    it 'keeps a NUL byte in an html body as before: the HTML parser drops it' do
      comment(body: "a#{0.chr}b")
      expect(response).to have_http_status(:created)
      expect(body.dig('data', 'body_text')).to eq('ab')
    end

    it 'takes a body that is no string as its text, as before' do
      comment_json({ body: true })
      expect(response).to have_http_status(:created)
      expect(body.dig('data', 'body_html')).to eq('true')
    end

    # The old gate was body.present?: false was no body, while true and numbers
    # were their text.
    it 'takes a JSON false as no body, as before' do
      expect { comment_json({ body: false }) }.not_to(change { posts_count })
      expect(response.body).to eq('{"error":"validation_failed","code":"invalid_input","errors":["Content can\'t be blank"]}')
    end

    it 'leaves an empty body to the model, which refuses it with its own message' do
      expect { comment(body: '') }.not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to eq('{"error":"validation_failed","code":"invalid_input","errors":["Content can\'t be blank"]}')
    end

    it 'checks the write right before the empty body, as before' do
      ActsAsTenant.with_tenant(organisation) { ProjectPermission.find_by!(user: user).update!(tickets_access: :read_only) }
      comment(body: '   ')
      expect(response).to have_http_status(:forbidden)
      expect(body).to eq('error' => 'forbidden', 'code' => 'forbidden')
    end

    it 'answers an empty body with a foreign addressee with every model message, as before' do
      expect { comment(body: '', is_private: true, visible_to_user_id: SecureRandom.uuid) }.not_to(change { posts_count })
      expect(response.body).to eq({ error: 'validation_failed', code: 'invalid_input',
                                    errors: ["Content can't be blank", 'Visible to user must be set for private posts',
                                             'Visible to user must be a member of the organisation'] }.to_json)
    end
  end

  describe 'refusals: 422 invalid_input, nothing written' do
    {
      'an unknown format' => [{ format: 'markdown', body: 'x' }, :format_unknown],
      'a format in capitals' => [{ format: 'PLAIN', body: 'x' }, :format_unknown],
      'an empty format' => [{ format: '', body: 'x' }, :format_unknown],
      'an empty plain body' => [{ format: 'plain', body: '' }, :body_empty],
      'a plain body of blank lines' => [{ format: 'plain', body: " \n\t\r\n " }, :body_empty],
      'a plain body of a no-break space' => [{ format: 'plain', body: -> { nbsp } }, :body_empty],
      'a plain body of an em space' => [{ format: 'plain', body: -> { 0x2003.chr(Encoding::UTF_8) } }, :body_empty],
      'a NUL byte in a plain body' => [{ format: 'plain', body: "a#{0.chr}b" }, :body_nul]
    }.each do |label, (fields, key)|
      it "refuses #{label}" do
        fields = fields.transform_values { |value| value.is_a?(Proc) ? instance_exec(&value) : value }
        expect { comment(**fields) }.not_to(change { posts_count })
        expect(response).to have_http_status(:unprocessable_content)
        expect(body).to eq(refusal(key))
      end
    end

    # Strong parameters let numbers and booleans through, and drop lists and
    # objects: without reading the raw value, a list as format would have
    # written the comment as html.
    { 'a number' => 1, 'a boolean' => true, 'null' => nil, 'a list' => ['plain'], 'an object' => { 'name' => 'plain' } }
      .each do |label, format|
        it "refuses #{label} as format over JSON, never a crash" do
          expect { comment_json({ format: format, body: 'x' }) }.not_to(change { posts_count })
          expect(response).to have_http_status(:unprocessable_content)
          expect(body).to eq(refusal(:format_not_string))
        end
      end

    it 'refuses a NUL byte in a plain body sent as JSON' do
      expect { comment_json({ format: 'plain', body: "a#{0.chr}b" }) }.not_to(change { posts_count })
      expect(body).to eq(refusal(:body_nul))
    end

    it 'refuses a plain body that is a list or an object as empty' do
      expect { comment_json({ format: 'plain', body: ['x'] }) }.not_to(change { posts_count })
      expect(body).to eq(refusal(:body_empty))
    end

    it 'refuses a JSON false as a plain body as empty' do
      expect { comment_json({ format: 'plain', body: false }) }.not_to(change { posts_count })
      expect(body).to eq(refusal(:body_empty))
    end

    it 'answers the refusal in the token owner language' do
      user.update!(language_preference: 'de')
      comment(format: 'markdown', body: 'x')
      expect(body).to eq(refusal(:format_unknown, locale: :de))
    end

    # Rails refuses a parameter that is no valid UTF-8 while it parses the
    # request, before any of this endpoint's code runs: over REST the rule's
    # body_invalid_utf8 is reached only by a plain multipart part declared
    # binary (below); MCP reaches it with invalid bytes in a JSON string.
    it 'never lets invalid UTF-8 reach the rule: Rails answers 400 first' do
      expect do
        post "/api/v1/tickets/#{ticket.id}/posts", params: 'post[format]=plain&post[body]=a%FFb',
                                                   headers: headers.merge('Content-Type' => 'application/x-www-form-urlencoded')
      end.not_to(change { posts_count })
      expect(response).to have_http_status(:bad_request)
    end

    it 'never lets invalid UTF-8 in a JSON body reach the rule either' do
      raw = "{\"post\":{\"format\":\"plain\",\"body\":\"a#{255.chr}b\"}}".b
      expect { post "/api/v1/tickets/#{ticket.id}/posts", params: raw, headers: headers(json: true) }
        .not_to(change { posts_count })
      expect(response).to have_http_status(:bad_request)
    end

    # An escaped lone surrogate is no JSON the parser takes: the 400 of a body
    # that is no JSON, which BaseController answers with code.
    it 'answers an escaped lone surrogate in JSON as a body that is no JSON' do
      raw = "{\"post\":{\"format\":\"plain\",\"body\":\"a#{92.chr}ud800b\"}}"
      expect { post "/api/v1/tickets/#{ticket.id}/posts", params: raw, headers: headers(json: true) }
        .not_to(change { posts_count })
      expect(response).to have_http_status(:bad_request)
      expect(body).to include('error' => 'bad_request', 'code' => 'invalid_input')
    end

    it 'answers a post that is no object like a missing one, never a crash' do
      post "/api/v1/tickets/#{ticket.id}/posts", params: {}, headers: headers
      missing = [response.status, response.body]
      expect { comment_json('abc') }.not_to(change { posts_count })
      expect([response.status, response.body]).to eq(missing)
      expect(missing.first).to eq(400)
    end
  end

  # Only a multipart part can carry another encoding (text/plain; charset=...).
  describe 'a multipart part in an encoding of its own' do
    def latin1 = "a#{0xE4.chr}b"
    def a_umlaut_b = "a#{0xE4.chr(Encoding::UTF_8)}b"

    it 'keeps an html part as it came, as before: a Latin-1 comment keeps its letters' do
      comment_multipart('body' => ['text/plain; charset=iso-8859-1', latin1])
      expect(response).to have_http_status(:created)
      expect(body.dig('data', 'body_text')).to eq(a_umlaut_b)
    end

    it 'keeps an html part declared binary as it came, as before (ActionText reads it)' do
      comment_multipart('body' => ['text/plain; charset=binary', "a#{0xFF.chr}b"])
      expect(response).to have_http_status(:created)
      expect(body.dig('data', 'body_text')).to eq("a#{0xFF.chr(Encoding::UTF_8)}b")
    end

    it 'transcodes a plain part to UTF-8' do
      comment_multipart('format' => [nil, 'plain'], 'body' => ['text/plain; charset=iso-8859-1', "#{latin1}\n<b>"])
      expect(response).to have_http_status(:created)
      expect(body.dig('data', 'body_text')).to eq("#{a_umlaut_b}\n<b>")
      expect(body.dig('data', 'body_html')).to eq("<p>#{a_umlaut_b}<br>&lt;b&gt;</p>")
    end

    # 0x81 has no character in Windows-1252: the part cannot be transcoded. The
    # client declared no UTF-8, so the text names what failed, the reading.
    it 'refuses a plain part whose charset does not transcode, writing nothing' do
      expect { comment_multipart('format' => [nil, 'plain'], 'body' => ['text/plain; charset=windows-1252', "a#{0x81.chr}b"]) }
        .not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to eq(refusal(:body_invalid_utf8))
      expect(body['errors']).to eq(['The comment (post[body]) cannot be read as UTF-8.'])
    end

    it 'refuses a plain part declared binary that holds no UTF-8, writing nothing' do
      expect { comment_multipart('format' => [nil, 'plain'], 'body' => ['text/plain; charset=binary', "a#{0xFF.chr}b"]) }
        .not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to eq(refusal(:body_invalid_utf8))
    end
  end

  describe 'who may comment' do
    def hide_ticket
      ActsAsTenant.with_tenant(organisation) do
        ProjectPermission.find_by!(user: user).update!(tickets_access: :no_access, notes_access: :read_only)
      end
    end

    it 'answers a missing and a hidden ticket the same, writing nothing' do
      comment(ticket_id: SecureRandom.uuid, format: 'plain', body: 'x')
      missing = [response.status, response.body]
      hide_ticket
      expect { comment(format: 'plain', body: 'x') }.not_to(change { posts_count })
      expect([response.status, response.body]).to eq(missing)
      expect(missing).to eq([404, { error: 'not_found', code: 'not_found' }.to_json])
    end

    # The input is checked inside the read gate: a refusal of it only ever
    # answers for a ticket the token can read, so it tells nothing the 404 does not.
    it 'answers a hidden ticket with an unusable comment like a missing one' do
      comment(ticket_id: SecureRandom.uuid, format: 'markdown', body: '')
      missing = [response.status, response.body]
      hide_ticket
      comment(format: 'markdown', body: '')
      expect([response.status, response.body]).to eq(missing)
      expect(missing.first).to eq(404)
    end

    it 'answers a ticket of another organisation like a missing one' do
      other = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:ticket, project: create(:project, organisation: other), organisation: other, creator: create(:user))
      end
      comment(ticket_id: SecureRandom.uuid, format: 'plain', body: 'x')
      missing = [response.status, response.body]
      expect { comment(ticket_id: foreign.id, format: 'plain', body: 'x') }.not_to(change { posts_count })
      expect([response.status, response.body]).to eq(missing)
    end

    it 'refuses a plain comment without the write right in the project, writing nothing' do
      ActsAsTenant.with_tenant(organisation) { ProjectPermission.find_by!(user: user).update!(tickets_access: :read_only) }
      expect { comment(format: 'plain', body: 'x') }.not_to(change { posts_count })
      expect(response).to have_http_status(:forbidden)
      expect(body).to eq('error' => 'forbidden', 'code' => 'forbidden')
    end

    context 'with a read-only token' do
      let(:read_only) { true }

      it 'refuses before anything else, writing nothing' do
        expect { comment(format: 'plain', body: 'x') }.not_to(change { posts_count })
        expect(response).to have_http_status(:forbidden)
        expect(body).to eq('error' => 'forbidden', 'code' => 'read_only')
      end

      it 'refuses an unusable comment the same way' do
        comment(format: 'markdown', body: "a#{0.chr}")
        expect(body).to eq('error' => 'forbidden', 'code' => 'read_only')
      end
    end
  end

  # The web comment is Actors::SavePost. A bare Post#save beside it produced no
  # activity, no notification and no embedding until 2026-10-10.
  describe 'side effects of the web form (Actors::SavePost)' do
    let(:subscriber) { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: subscriber, organisation: organisation, role: role, active: true)
        create(:project_permission, user: subscriber, project: project, tickets_access: :read_write)
        NotificationSubscription.create!(user: subscriber, subscribable: ticket, mode: :follow)
      end
    end

    def activity_for(post_record)
      ActsAsTenant.without_tenant { Activity.find_by!(action: 'post_added', secondary: post_record) }
    end

    def fan_out(post_record)
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          Notifications::FanoutService.new(OutboxEvent.find_by!(activity: activity_for(post_record))).call
        end
      end
    end

    def notified?(recipient)
      ActsAsTenant.without_tenant do
        Notification.where(recipient: recipient, notifiable: ticket, event_type: 'ticket_commented').exists?
      end
    end

    it 'writes through Actors::SavePost' do
      expect(Actors::SavePost).to receive(:new).and_call_original
      comment(format: 'plain', body: 'Hallo')
      expect(response).to have_http_status(:created)
    end

    # Every other example comments on a ticket the token owner created, where
    # the owner and the creator are the same person.
    it 'writes as the token owner on a ticket somebody else created' do
      creator = create(:user)
      foreign = ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: creator, organisation: organisation, role: role, active: true)
        create(:ticket, project: project, organisation: organisation, creator: creator)
      end
      comment(ticket_id: foreign.id, format: 'plain', body: 'Hallo')
      expect(response).to have_http_status(:created)
      expect(body.dig('data', 'author', 'id')).to eq(user.id)
      expect(saved.user_id).to eq(user.id)
      ActsAsTenant.with_tenant(organisation) { expect(activity_for(saved).actor).to eq(user) }
    end

    it 'enqueues the embedding of the comment' do
      allow(EmbeddingProcessingJob).to receive(:perform_later)
      comment(format: 'plain', body: 'Hallo')
      expect(EmbeddingProcessingJob).to have_received(:perform_later)
        .with(record_class: Post, record_id: body.dig('data', 'id'), fragment_association: :fragments)
    end

    it 'records a post_added activity with the excerpt of the text' do
      comment(format: 'plain', body: "Hallo <b>\nWelt")
      activity = activity_for(saved)
      ActsAsTenant.with_tenant(organisation) do
        expect(activity.trackable).to eq(ticket)
        expect(activity.actor).to eq(user)
      end
      expect(activity.parameters['post_excerpt']).to eq("Hallo <b>\nWelt")
    end

    it 'reaches a subscriber as ticket_commented through the outbox' do
      comment(format: 'plain', body: 'Hallo')
      fan_out(saved)
      expect(notified?(subscriber)).to be(true)
    end

    it "marks the author's own unread notifications about the ticket as read" do
      own = ActsAsTenant.with_tenant(organisation) do
        create(:notification, :ticket_commented, organisation: organisation, recipient: user, actor: subscriber,
                                                 notifiable: ticket, project: project)
      end
      comment(format: 'plain', body: 'Hallo')
      expect(ActsAsTenant.without_tenant { own.reload.state }).to eq('read')
    end

    describe 'a private plain comment' do
      it 'carries no excerpt and notifies no subscriber it is not addressed to' do
        comment(format: 'plain', body: 'Nur an mich', is_private: true)
        expect(body.dig('data', 'is_private')).to be(true)
        expect(body.dig('data', 'visible_to_user_id')).to eq(user.id)
        expect(activity_for(saved).parameters).not_to have_key('post_excerpt')
        fan_out(saved)
        expect(notified?(subscriber)).to be(false)
      end

      it 'notifies its addressee' do
        comment(format: 'plain', body: 'An dich', is_private: 'true', visible_to_user_id: subscriber.id)
        expect(body.dig('data', 'visible_to_user_id')).to eq(subscriber.id)
        fan_out(saved)
        expect(notified?(subscriber)).to be(true)
      end
    end
  end

  # The same input writes the same post on both surfaces: one rule, two hulls.
  it 'writes the post the MCP tool writes for the same input' do
    text = "Zeile 1\r\nZeile 2\n\n<b>&</b>"
    comment(format: 'plain', body: text, is_private: true)
    rest = saved

    context = Lalabase::Tools::Context.new(actor: user, organisation: organisation, project: project,
                                           authorization: Lalabase::Tools::AuthorizationRecorder.new)
    result = ActsAsTenant.with_tenant(organisation) do
      Lalabase::Tools::PostComment.execute(args: { ticket_id: ticket.id, format: 'plain', body: text, is_private: true },
                                           context: context)
    end
    mcp = ActsAsTenant.without_tenant { Post.find(JSON.parse(result.content).fetch('id')) }

    # Read outside the requests: one rich text per post, asked twice from one line.
    fields = ->(record) { [record.content.body.to_html, record.plain_text_version, record.is_private, record.user_id, record.visible_to_user_id, record.ticket_id] }
    Prosopite.pause do
      ActsAsTenant.without_tenant { expect(fields.call(mcp)).to eq(fields.call(rest)) }
    end
  end

  describe 'a failed save' do
    def failing_save(code, errors)
      allow_any_instance_of(Actors::SavePost).to receive(:call)
        .and_return(Actors::BaseActor::Result.new(success: false, errors: errors, code: code))
    end

    # BaseActor answers an exception it did not expect as :internal_error with
    # the exception's text where it does not re-raise (production).
    it 'answers an unexpected failure as a server error without its text' do
      failing_save(:internal_error, ['PG::ConnectionBad: could not connect to server at 192.168.0.1'])
      comment(format: 'plain', body: 'x')
      expect(response).to have_http_status(:internal_server_error)
      expect(response.body).not_to include('PG::', '192.168.0.1')
      expect(body).to eq('error' => 'internal_error', 'code' => 'refused', 'reason' => 'internal_error')
    end

    it 'answers every other failure as it always did' do
      failing_save(:validation_failed, ['Visible to user must be a member of the organisation'])
      comment(body: 'x')
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to eq('error' => 'validation_failed', 'code' => 'invalid_input',
                         'errors' => ['Visible to user must be a member of the organisation'])
    end
  end

  describe 'Idempotency-Key' do
    it 'replays the first answer for the same key and request, writing once' do
      expect { comment(key: 'r3a-1', format: 'plain', body: "a\nb") }.to change { posts_count }.by(1)
      first = [response.status, response.body]
      expect { comment(key: 'r3a-1', format: 'plain', body: "a\nb") }.not_to(change { posts_count })
      expect([response.status, response.body]).to eq(first)
    end

    it 'refuses the key with another body' do
      comment(key: 'r3a-2', format: 'plain', body: 'a')
      expect { comment(key: 'r3a-2', format: 'plain', body: 'b') }.not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include('error' => 'idempotency_key_reused', 'code' => 'invalid_input')
    end

    it 'refuses the key with another format' do
      comment(key: 'r3a-3', format: 'plain', body: 'a')
      expect { comment(key: 'r3a-3', format: 'html', body: 'a') }.not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include('error' => 'idempotency_key_reused', 'code' => 'invalid_input')
    end
  end
end
