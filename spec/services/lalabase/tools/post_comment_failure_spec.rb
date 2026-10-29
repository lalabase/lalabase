# frozen_string_literal: true

require 'rails_helper'

# What: what post_comment_spec.rb does not pin (REST R3a), beside it, so that
#       file stays as it was: every answer it pins is the tool's answer before
#       the rule moved into Posts::Comment. Here: the rule answers before the
#       ticket is looked up, and how a failed save is worded.
# Why:  The tool always refused unusable input before its lookup, so a missing
#       or hidden ticket with broken input answers invalid_input, not "No ticket
#       found". BaseActor answers an unexpected exception as :internal_error with
#       the exception's text where it does not re-raise (production); that text
#       may name the database and reached the client through "comment failed: ...".
RSpec.describe Lalabase::Tools::PostComment, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, organisation: organisation, project: project, creator: user) }
  let(:context) do
    Lalabase::Tools::Context.new(actor: user, organisation: organisation, project: project,
                                 authorization: Lalabase::Tools::AuthorizationRecorder.new)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation))
    create(:project_permission, user: user, project: project, tickets_access: :read_write)
  end

  after { ActsAsTenant.current_tenant = nil }

  def execute(arguments = {})
    described_class.execute(args: { ticket_id: ticket.id, body: 'Hallo', format: 'plain' }.merge(arguments), context: context)
  end

  def failing_save(code, errors)
    allow_any_instance_of(Actors::SavePost).to receive(:call)
      .and_return(Actors::BaseActor::Result.new(success: false, errors: errors, code: code))
  end

  describe 'before the ticket lookup' do
    it 'refuses an unknown format for a missing ticket' do
      result = execute(ticket_id: SecureRandom.uuid, format: 'markdown')
      expect(result.error_code).to eq(:invalid_input)
      expect(result.error).to eq('format must be html or plain')
    end

    it 'refuses an empty body for a missing ticket' do
      result = execute(ticket_id: SecureRandom.uuid, body: ' ')
      expect(result.error_code).to eq(:invalid_input)
      expect(result.error).to eq('body is required')
    end

    it 'refuses a NUL byte for a ticket the caller may not read' do
      ProjectPermission.find_by!(user: user, project: project).update!(tickets_access: :no_access)
      result = execute(body: "a#{0.chr}b")
      expect(result.error_code).to eq(:invalid_input)
      expect(result.error).to eq('body must not contain NUL bytes')
    end

    # An empty html body too: REST leaves it to the model after the write
    # check, MCP refuses it here, as it always did (app/services/CLAUDE.md).
    { 'format html' => { format: 'html' }, 'no format' => {} }.each do |label, format|
      it "refuses an empty html body for a missing ticket (#{label})" do
        result = described_class.execute(args: { ticket_id: SecureRandom.uuid, body: ' ' }.merge(format), context: context)
        expect(result.error_code).to eq(:invalid_input)
        expect(result.error).to eq('body is required')
      end
    end

    it 'refuses an empty html body for a ticket the caller may not read' do
      ProjectPermission.find_by!(user: user, project: project).update!(tickets_access: :no_access)
      result = described_class.execute(args: { ticket_id: ticket.id, body: ' ' }, context: context)
      expect(result.error_code).to eq(:invalid_input)
      expect(result.error).to eq('body is required')
    end
  end

  it 'enqueues the embedding of the comment, as the web form does' do
    allow(EmbeddingProcessingJob).to receive(:perform_later)
    result = execute
    expect(EmbeddingProcessingJob).to have_received(:perform_later)
      .with(record_class: Post, record_id: JSON.parse(result.content).fetch('id'), fragment_association: :fragments)
  end

  # The rule holds the reading of is_private (a JSON true or the string
  # "true", as the tool always took it); the tool must hand the value on.
  it 'takes is_private given as the string "true" as private' do
    result = execute(is_private: 'true')
    saved = Post.find(JSON.parse(result.content).fetch('id'))
    expect(saved).to be_private
    expect(saved.visible_to_user_id).to eq(user.id)
  end

  it 'answers an unexpected failure with a fixed text, never the exception text' do
    failing_save(:internal_error, ['PG::ConnectionBad: could not connect to server at 192.168.0.1'])
    result = execute
    expect(result).not_to be_success
    expect(result.error).to eq('comment failed: unexpected error')
    expect(result.error_code).to eq(:refused)
  end

  # The author's subscription runs after the commit (Post after_create_commit).
  # The comment stands, so the tool answers it: an error would invite a retry
  # that writes it a second time.
  it 'answers a comment written before a failure after the commit with the comment' do
    ticket
    allow(NotificationSubscription).to receive(:system_subscribe).and_raise(ActiveRecord::ConnectionNotEstablished, 'gone')
    original = Rails.application.config.x.actors.reraise_unexpected
    Rails.application.config.x.actors.reraise_unexpected = false

    result = nil
    expect { result = execute }.to change(Post, :count).by(1)
    expect(result).to be_success
    expect(Post.find(JSON.parse(result.content).fetch('id'))).to be_persisted
  ensure
    Rails.application.config.x.actors.reraise_unexpected = original
  end

  it 'still names the reason of any other failure, as before' do
    failing_save(:validation_failed, ['Content darf nicht leer sein'])
    result = execute
    expect(result.error).to eq('comment failed: Content darf nicht leer sein')
    expect(result.error_code).to eq(:refused)
  end

  it 'answers a model refusal of the stored body with the model text, as before' do
    result = nil
    expect { result = execute(format: 'html', body: '<p></p>') }.not_to change(Post, :count)
    expect(result.error).to match(/\Acomment failed: Content /)
  end
end
