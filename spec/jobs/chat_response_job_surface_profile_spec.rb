# frozen_string_literal: true

require 'rails_helper'

# The answering profile of the chat surfaces as ONE table, every cell an
# example (doc/chat_oberflaechen_profil_plan.md §5.2; decided 26.08.2026: the
# pins first and no Chats::Surface registry, assistant plan §13-19).
#
# ChatResponseJob derives its settings from one predicate (Chat#org_thread?),
# each in its own branch, and chat_response_job_spec.rb pins those branches one
# method at a time. Nobody asked "does every surface have a COMPLETE profile?",
# and while the ticket chat still existed two of its branches had no pin at all
# (plan §1.4): a deleted `return :ticket_chat` and a `name_projects:` pinned to
# false both left the 142-example job spec green, falling back to the
# project-chat default silently.
#
# This file is that missing place. Rows are the surfaces, columns the settings,
# so a drifting row or column names itself in the failure output. It pins the
# OBSERVABLE behaviour (what reaches the Runner, what the model reads), not a
# storage shape. S4-T1 dissolved the ticket chat and with it the ticket row of this
# table (26.08.2026); projekt_chat_abbau dissolved the per-project chat and its row
# (30.08.2026). ONE row is left, and that is fine: the frame examples below are what
# carry the value now -- they pin that the table's rows and the Registry's chat sets
# are the same list, and that the surface sits in the partition it names. A surface
# that comes back is a new row here first.
#
# The historical pins stay where they are (runner wiring, org-wide thread, tool
# hint in chat_response_job_spec.rb); they carry nuance this table does not
# (absolute DE strings, the archived-chip case, end-to-end runs).
#
# The Runner cells pin the CALL FORM on purpose: tool_set and max_iterations are
# passed explicitly even where they equal the Runner's defaults, because the job
# naming the surface's set is the seam Runner#initialize documents. A refactor
# that leaves them to the defaults turns those cells red; fix the job, not the cell.
RSpec.describe ChatResponseJob, 'surface profile table', type: :job do
  # One row per surface, the key is the surface's kind (= the Runner tool set
  # that names it). Values read off the job on 26.08.2026, before any refactor;
  # the column names are the plan's field names so a registry maps 1:1.
  #   tool_free         -> Runner max_iterations (1 is the Runner's no-tool-rounds sentinel)
  #   content_retrieval -> whether #respond runs the project-content retrieval
  #   name_projects     -> whether retrieved content is labelled with its project
  #   scope_hint        -> whether a resolved scope chip is announced to the model
  #   reference_hint    -> whether a resolved reference is announced to the model
  profiles = {
    assistant: {
      system_prompt_key: 'jobs.ai_chat.assistant_system_prompt',
      tool_hint_key: 'jobs.ai_chat.assistant_tool_hint',
      # TWO cells, not one with a condition inside. The assistant's set depends on
      # ORG DATA (does the organisation have a connected repository at all), not on
      # the surface, and a conditional hidden in one cell would defeat the table --
      # the very failure this file exists to catch.
      tool_sets: { without_repository: :assistant, with_repository: :assistant_with_code },
      # The extra hint sentence rides in the same branch as the extra tools: a set
      # advertised without its sentence promises a reach the code tools do not have.
      code_hint_key: 'jobs.ai_chat.assistant_tool_hint_code',
      tool_free: false,
      content_retrieval: true,
      name_projects: true,
      scope_hint: true,
      reference_hint: true
    }
  }.freeze

  # The model partition each row stands on (the two scopes in chat.rb, which
  # mirror the predicate the job dispatches on). Not computable from anywhere:
  # the kinds ARE the partition of the chat columns, so this list is the honest
  # mirror, and a third kind has to change both the model and this table.
  partitions = {
    assistant: :org_threads
  }.freeze

  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation, name: 'Website Relaunch') }
  let(:provider)     { instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai') }
  let(:job)          { described_class.new }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # One fixture per row: the org thread has no project and an owner, the
  # project chat has its project. Total over the table: a row without a fixture
  # fails loudly.
  def surface_chat_for(kind)
    case kind
    when :assistant
      create(:chat, organisation: organisation, user: create(:user))
    else
      raise ArgumentError, "no fixture for surface #{kind.inspect}"
    end
  end

  # The one piece of ORG DATA a surface cell depends on: the organisation has a
  # connected repository. Deliberately just the repository and no index -- that is
  # the question the job asks (ChatResponseJob#code_tools?), and asking a different
  # one here would pin a rule the job does not have.
  def connect_repository
    create(:project_repository, project: project, organisation: organisation)
  end

  # A retrieval result with ONE content item from a ticket of `project`: the
  # name_projects column needs content that HAS an origin to label.
  def content_result
    ticket = create(:ticket, project: project, organisation: organisation, title: 'Login bug')
    fragment = create(:fragment, fragmentable: ticket, organisation: organisation, plain_text_content: 'steps')
    Lalabase::ProjectRag::Retriever::Result.new(vision: nil, capabilities: [], symbols: [],
                                                content: [fragment], citations: [])
  end

  # The narrowings as the job sees them: ONE double for both hint columns, because
  # the job asks the SAME Tools::Scope for both. Two hand-built doubles would let a
  # column stay green against a scope object that never existed -- one answering
  # only #selection, the other only #references, while the job calls both.
  def narrowed_scope(selection: nil, references: [])
    instance_double(Lalabase::Tools::Scope, selection: selection, references: references)
  end

  # Drives #generate_answer against a stubbed Runner and pins what the job hands it.
  def expect_runner_built_with(chat, **args)
    runner = instance_double(Lalabase::Tools::Runner, citations: [], tool_calls_log: [])
    allow(runner).to receive(:call).and_return({ content: 'x', model_used: 'm', token_usage: {} })
    allow(job).to receive(:track_ai_usage)
    message = chat.chatposts.create!(role: 'assistant', content: '', organisation: organisation)
    expect(Lalabase::Tools::Runner).to receive(:new).with(hash_including(**args)).and_return(runner)
    job.send(:generate_answer, chat, message, provider, [], [])
  end

  # Drives #respond up to and through the retrieval decision. Stubbed: the
  # language lock, the provider, the answer, and the Retriever itself (its
  # constructor is the seam the content_retrieval column observes). History
  # assembly and the placeholder post still run for real, so a failure there is
  # a real failure.
  def run_respond(chat)
    retriever = instance_double(Lalabase::ProjectRag::Retriever, call: nil)
    allow(Lalabase::ProjectRag::Retriever).to receive(:new).and_return(retriever)
    allow(job).to receive_messages(detect_and_lock_language: nil, resolve_provider: provider, generate_answer: nil)
    job.send(:respond, chat)
  end

  # A surface text as the model reads it. raise: true, because a key missing in
  # BOTH locales renders "Translation missing: ..." on both sides of a comparison,
  # and a cell would stay green while that string IS the model's framing.
  #
  # `limit:` is the value the job interpolates into the assistant hint; the other
  # texts ignore it. Without it the expected hint keeps a literal %{limit} and
  # can never be found in the prompt.
  def surface_text(key, **args)
    I18n.t(key, raise: true, limit: job.send(:full_text_limit_label), **args)
  end

  # The frame around the rows: every chat set the tools Registry offers has a
  # surface row here and vice versa. The Runner cell alone would stay green with a
  # set the Registry does not know (Runner.new is stubbed there), and when S4-T1
  # removed the ticket row this forced CHAT_SETS to shrink with it: a chat set
  # without a surface is a dead tool catalogue.
  it 'names exactly the chat sets the tools Registry offers' do
    expect(profiles.values.flat_map { |row| row[:tool_sets].values }.uniq)
      .to match_array(Lalabase::Tools::Registry::CHAT_SETS)
  end

  profiles.each do |kind, profile|
    context "for the #{kind} surface" do
      let(:surface_chat) { surface_chat_for(kind) }

      # Column 1, the row header: the fixture sits in exactly the partition the
      # row names, so every other cell of the row is measured on the right chat.
      it "sits in the #{partitions.fetch(kind)} partition and in no other" do
        chat = surface_chat
        member_of = partitions.select { |_, scope| Chat.public_send(scope).exists?(chat.id) }.keys

        expect(member_of).to eq([kind])
      end

      it "frames the answer with #{profile[:system_prompt_key]} and no other framing" do
        out = job.send(:system_prompt_with_context, surface_chat, nil)
        own = surface_text(profile[:system_prompt_key])
        others = profiles.values.map { |row| surface_text(row[:system_prompt_key]) } - [own]

        expect(out).to include(own)
        others.each { |text| expect(out).not_to include(text) }
      end

      it "advertises #{profile[:tool_hint_key] || 'no tool hint'} and no other hint" do
        out = job.send(:system_prompt_with_context, surface_chat, nil)
        own = profile[:tool_hint_key] && surface_text(profile[:tool_hint_key])
        others = profiles.values.filter_map { |row| row[:tool_hint_key] && surface_text(row[:tool_hint_key]) } - [own]

        expect(out).to include(own) if own
        others.each { |text| expect(out).not_to include(text) }
      end

      profile[:tool_sets].each do |condition, set|
        it "names the Runner tool set #{set.inspect} for an organisation #{condition.to_s.tr('_', ' ')}" do
          connect_repository if condition == :with_repository

          expect_runner_built_with(surface_chat, tool_set: set)
        end
      end

      # The hint half of the same branch. Both directions, because the failure that
      # matters is a set without its sentence (the prompt then promises the code
      # tools reach every project) and a sentence without the set (it advertises
      # tools that were never offered).
      it "advertises #{profile[:code_hint_key] || 'no'} code sentence without a repository" do
        out = job.send(:system_prompt_with_context, surface_chat, nil)

        expect(out).not_to include(surface_text('jobs.ai_chat.assistant_tool_hint_code'))
      end

      it "advertises #{profile[:code_hint_key] ? 'the code sentence' : 'still no code sentence'} with a repository" do
        connect_repository
        out = job.send(:system_prompt_with_context, surface_chat, nil)
        code_sentence = surface_text('jobs.ai_chat.assistant_tool_hint_code')

        if profile[:code_hint_key]
          expect(out).to include(code_sentence)
        else
          expect(out).not_to include(code_sentence)
        end
      end

      it "runs #{profile[:tool_free] ? 'tool-free (max_iterations: 1)' : 'with tool rounds (default max_iterations)'}" do
        expected = profile[:tool_free] ? 1 : Lalabase::Tools::Runner::DEFAULT_MAX_ITERATIONS

        expect_runner_built_with(surface_chat, max_iterations: expected)
      end

      # Observed at the Retriever seam, not at the job's private method, so the
      # org path's own guard inside #retrieve_rag_context (a project-less chat
      # that is not an org thread retrieves nothing) sits under this cell too.
      # The generate_answer anchor proves the flow reached the decision at all:
      # #respond rescues every StandardError into an error bubble, so a crash
      # before the decision would otherwise leave the negative branch green for
      # a reason that has nothing to do with retrieval.
      it "#{profile[:content_retrieval] ? 'runs' : 'skips'} the project-content retrieval" do
        run_respond(surface_chat)

        expect(job).to have_received(:generate_answer)
        if profile[:content_retrieval]
          expect(Lalabase::ProjectRag::Retriever).to have_received(:new).with(hash_including(chat: surface_chat))
        else
          expect(Lalabase::ProjectRag::Retriever).not_to have_received(:new)
        end
      end

      # The content is in the prompt on every row (the item itself is not the
      # question); the cell is the origin label next to it.
      it "#{profile[:name_projects] ? 'labels' : 'does not label'} retrieved content with its project" do
        out = job.send(:system_prompt_with_context, surface_chat, content_result)

        expect(out).to include('Login bug')
        if profile[:name_projects]
          expect(out).to include('(project: Website Relaunch)')
        else
          expect(out).not_to include('(project: Website Relaunch)')
        end
      end

      # Every row is handed a RESOLVED selection, so the only reason left for a
      # missing hint is the surface: not "no chip", and not Tools::Scope.for
      # answering nil off the org path (it does, a second bolt this column looks
      # past on purpose; a job that announced the chip on every surface would
      # otherwise stay green here for that unrelated reason). The resolution
      # itself, membership and the archived chip, is pinned in the org-wide
      # thread block of chat_response_job_spec.rb.
      it "#{profile[:scope_hint] ? 'announces' : 'does not announce'} a narrowed scope to the model" do
        allow(Lalabase::Tools::Scope).to receive(:for).and_return(narrowed_scope(selection: project))
        out = job.send(:system_prompt_with_context, surface_chat, nil)
        hint = surface_text('jobs.ai_chat.assistant_scope_hint', project: 'Website Relaunch')

        if profile[:scope_hint]
          expect(out).to include(hint)
        else
          expect(out).not_to include(hint)
        end
      end

      # The second narrowing (S4 T2, §7.3), its own column because it carries what
      # the scope hint does not: the SUBJECT of the conversation. A surface that
      # announced the chip but swallowed the reference would leave every follow-up
      # question without an antecedent while this table still read all-green.
      # Handed a RESOLVED reference for the same reason as the cell above.
      it "#{profile[:reference_hint] ? 'announces' : 'does not announce'} a ticket reference to the model" do
        ticket = create(:ticket, project: project, organisation: organisation, title: 'Login bug')
        allow(Lalabase::Tools::Scope).to receive(:for).and_return(narrowed_scope(references: [ticket]))
        out = job.send(:system_prompt_with_context, surface_chat, nil)
        hint = surface_text(
          'jobs.ai_chat.assistant_reference_hint', count: 1,
                                                   list: surface_text('jobs.ai_chat.reference_items.ticket',
                                                                      title: ticket.one_line_title(max: ChatResponseJob::MAX_REFERENCE_TITLE_CHARS),
                                                                      project: 'Website Relaunch', id: ticket.id)
        )

        if profile[:reference_hint]
          expect(out).to include(hint)
        else
          expect(out).not_to include(hint)
        end
      end
    end
  end
end
