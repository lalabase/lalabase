# frozen_string_literal: true

require 'rails_helper'

# S3a T5: the org-wide reach is resolved in SEVERAL places -- Tools::Runner for
# the tool rounds, ProjectRag::Retriever for the content layer, ChatResponseJob
# for the scope hint in the system prompt, ScopeChipComponent for what the chip
# shows. Before T5 each built a Tools::Scope by hand, and the scope chip would
# then have had to be threaded into every one of them by hand as well.
#
# That is the shape of defect this whole slice kept producing: a rule enforced in
# several places, correct in some of them. This guard keeps them on the ONE
# factory so the next thing the scope learns cannot reach only half the
# assistant.
#
# It scans app/ WHOLESALE rather than a hand-kept list of call sites. A list is
# the same duplicated enforcement the guard exists to prevent: T5 added two call
# sites, and a two-entry list would not have noticed either of them.
RSpec.describe 'Tools::Scope has a single factory', type: :model do
  # The factory's own file is where `new` legitimately lives.
  let(:own_file) { 'app/services/lalabase/tools/scope.rb' }

  let(:sources) do
    Dir.glob(Rails.root.join('app/**/*.rb'))
       .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
       .reject { |path| path == own_file }
       .index_with { |path| Rails.root.join(path).read }
  end

  # Files that actually BUILD a scope, by either route. Matched on the call shape
  # rather than on the constant, so a file that only mentions Tools::Scope in a
  # comment is not a call site, and an unrelated `Scope.new` (of which the Pundit
  # policies have many) cannot fail the guard.
  let(:call_sites) do
    sources.select { |_path, body| body.match?(/(?:Tools::)?Scope\.(?:for\(chat:|new\(organisation:)/) }
  end

  it 'is never constructed directly outside its own class' do
    offenders = call_sites.select { |_path, body| body.match?(/(?:Tools::)?Scope\.new\(organisation:/) }

    expect(offenders.keys).to be_empty, <<~MESSAGE
      Tools::Scope.new is called directly. Use Tools::Scope.for(chat:, actor:) --
      it is the one place that knows about the scope chip, and a second
      construction is a second place to forget it.

      #{offenders.keys.join("\n")}
    MESSAGE
  end

  # The counter-example to the counter-example: the scan must actually FIND the
  # call sites, or an empty offender list would prove nothing.
  it 'sees every call site the assistant resolves its reach in' do
    expect(call_sites.keys).to include(
      'app/services/lalabase/tools/runner.rb',
      'app/services/lalabase/project_rag/retriever.rb',
      'app/jobs/chat_response_job.rb',
      'app/components/neo/chat/scope_chip_component.rb',
      'app/components/neo/chat/reference_chip_component.rb'
    )
  end

  # The counter-example: the guard must not be satisfiable by deleting the
  # resolution altogether.
  it 'the factory still resolves an org thread' do
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      user = create(:user)
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
      chat = create(:chat, :org_thread, organisation: organisation, user: user)

      expect(Lalabase::Tools::Scope.for(chat: chat, actor: user)).to be_a(Lalabase::Tools::Scope)
    end
  end
end
