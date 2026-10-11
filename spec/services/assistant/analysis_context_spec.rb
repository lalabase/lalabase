# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Assistant::AnalysisContext do
  before { ActsAsTenant.current_tenant = build_stubbed(:organisation) }
  after { ActsAsTenant.current_tenant = nil }

  let(:meeting_id) { SecureRandom.uuid }
  let(:citation) { { 'type' => 'meeting', 'id' => meeting_id, 'project_id' => SecureRandom.uuid } }
  let(:question) do
    Chatpost.new(analysis_context: {
                   'references' => [{ 'type' => 'Meeting', 'id' => meeting_id }], 'instruction' => 'Entscheidungen herausarbeiten.'
                 })
  end

  it 'requires both a submitted reference and server-observed meeting source' do
    context = described_class.call(question: question, history: [], citations: [citation])
    expect(context['meeting_ids']).to eq([meeting_id])
    expect(context['instructions']).to eq(['Entscheidungen herausarbeiten.'])
    expect(described_class.call(question: question, history: [], citations: [])['meeting_ids']).to be_empty
    question.analysis_context['references'] = []
    expect(described_class.call(question: question, history: [], citations: [citation])['meeting_ids']).to be_empty
  end

  it 'inherits the last result for a revision, preserving its instructions and all sources' do
    previous = Chatpost.new(role: :assistant, source_citations: [citation],
                            analysis_context: { 'meeting_ids' => [meeting_id], 'instructions' => ['Entscheidungen herausarbeiten.'], 'provenance' => [citation] })
    question.analysis_context['instruction'] = 'Kürzer.'
    context = described_class.call(question: question, history: [previous], citations: [], revision: previous)
    expect(context['meeting_ids']).to eq([meeting_id])
    expect(context['instructions']).to eq(['Entscheidungen herausarbeiten.', 'Kürzer.'])
    expect(context['provenance']).to eq([citation])
    question.analysis_context['instruction'] = 'Wie spät ist es?'
    expect(described_class.call(question: question, history: [previous], citations: [])['meeting_ids']).to be_empty
  end

  it 'does not migrate old questions implicitly' do
    question.analysis_context = nil
    expect(described_class.call(question: question, history: [], citations: [citation])).to be_nil
  end

  ['Bitte kürzer.', 'Please make it shorter.', 'Mach das bitte kürzer.'].each do |instruction|
    it "retains the target and instruction chain for #{instruction}" do
      previous = Chatpost.new(role: :assistant, analysis_context: { 'meeting_ids' => [meeting_id], 'instructions' => ['Analyse.'] })
      question.analysis_context['instruction'] = instruction
      context = described_class.call(question: question, history: [previous], citations: [], revision: previous)
      expect(context['meeting_ids']).to eq([meeting_id])
      expect(context['instructions']).to eq(['Analyse.', instruction])
    end
  end

  it 'does not treat reference metadata as a meeting read' do
    context = described_class.call(question: question, history: [], citations: [], reference_citations: [citation])
    expect(context['meeting_ids']).to be_empty
    expect(context['provenance']).to eq([citation])
  end

  %w[recent_activity list_tickets list_capabilities summarize_time_sessions get_ticket future_tool].each do |tool|
    it "refuses to certify partial citations from #{tool}" do
      context = described_class.call(question: question, history: [], citations: [citation],
                                     tool_calls: [{ 'tool' => tool, 'succeeded' => true }])
      expect(context['provenance']).to include('type' => 'unverified_tool_sources')
    end
  end

  it 'accepts an exact ticket read but not a number lookup that may return uncited project candidates' do
    context = described_class.call(question: question, history: [], citations: [citation],
                                   tool_calls: [{ 'tool' => 'get_ticket', 'succeeded' => true, 'args' => { 'ticket_id' => SecureRandom.uuid } }])
    expect(context['provenance']).to eq([citation])
    ambiguous = described_class.call(question: question, history: [], citations: [citation],
                                     tool_calls: [{ 'tool' => 'get_ticket', 'succeeded' => true,
                                                    'args' => { 'ticket_id' => SecureRandom.uuid, 'project' => 'Plan' } }])
    expect(ambiguous['provenance']).to include('type' => 'unverified_tool_sources')
  end

  it 'never treats a model unused flag as a permission to drop provenance' do
    unused = citation.merge('used' => false)
    previous = Chatpost.new(role: :assistant, source_citations: [unused])
    context = described_class.call(question: question, history: [previous], citations: [citation])
    expect(context['provenance']).to include(unused)
  end
  it 'marks legacy ticket drill-down history as unverifiable instead of losing private comment provenance' do
    old = Chatpost.new(role: :assistant, model_used: 'test', source_citations: [], tool_calls: [{ tool: 'get_ticket', succeeded: true }])
    context = described_class.call(question: question, history: [old], citations: [citation])
    expect(context['provenance']).to include('type' => 'unverified_history')
  end
  ['Nur eine Frage: Was ist im Projekt offen?', 'Nur kurz: Was ist neu?', 'Add the tickets from April', 'Ergänzend eine andere Frage'].each do |instruction|
    it "does not infer a revision from #{instruction}" do
      previous = Chatpost.new(role: :assistant, analysis_context: { 'meeting_ids' => [meeting_id], 'instructions' => ['Analyse.'] })
      question.analysis_context['instruction'] = instruction
      context = described_class.call(question: question, history: [previous], citations: [])
      expect(context['meeting_ids']).to be_empty
      expect(context['instructions']).to eq([instruction])
    end
  end

  it 'does not poison future answers with a quota or provider error bubble' do
    failed = Chatpost.new(role: :assistant, content: 'Quota exceeded', model_used: nil, analysis_context: { 'provenance' => [] })
    context = described_class.call(question: question, history: [failed], citations: [citation])
    expect(context['provenance']).to eq([citation])
  end

  it 'retains fail-closed markers from earlier completed answers' do
    %w[unverified_history unverified_tool_sources].each do |type|
      previous = Chatpost.new(role: :assistant, model_used: 'test', analysis_context: { 'provenance' => [{ 'type' => type }] })
      context = described_class.call(question: question, history: [previous], citations: [citation])
      expect(context['provenance']).to include('type' => type)
    end
  end
  it 'keeps the explicitly selected result target when current references have changed' do
    previous = Chatpost.new(role: :assistant, analysis_context: { 'meeting_ids' => [meeting_id], 'instructions' => ['Analyse.'], 'provenance' => [citation] })
    question.analysis_context['references'] = [{ 'type' => 'Meeting', 'id' => SecureRandom.uuid }]
    context = described_class.call(question: question, history: [], citations: [], revision: previous)
    expect(context['meeting_ids']).to eq([meeting_id])
    expect(context['provenance']).to eq([citation])
  end
end
