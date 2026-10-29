# frozen_string_literal: true

require 'rails_helper'

# What: how post_comment words a save that failed (REST R3a). Beside
#       post_comment_spec.rb, which stays as it was: every answer it pins is
#       the tool's answer before the rule moved into Posts::Comment.
# Why:  BaseActor answers an unexpected exception as :internal_error with the
#       exception's text where it does not re-raise (production). That text may
#       name the database and reached the client through "comment failed: ...".
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

  it 'answers an unexpected failure with a fixed text, never the exception text' do
    failing_save(:internal_error, ['PG::ConnectionBad: could not connect to server at 192.168.0.1'])
    result = execute
    expect(result).not_to be_success
    expect(result.error).to eq('comment failed: unexpected error')
    expect(result.error_code).to eq(:refused)
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
