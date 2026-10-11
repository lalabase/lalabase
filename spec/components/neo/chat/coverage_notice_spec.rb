# frozen_string_literal: true

require 'rails_helper'

# S3a T5 (§9.3, L7): after the scope chip there are TWO reasons an answer looked
# at less than everything, and they must not sound alike.
#
#   * the user chose it   -> "Durchsucht: nur Nordlicht"
#   * the rights end here -> "Durchsucht: 3 von 12 Projekten"
#
# The second is the original L7 promise (never narrow silently). The first is new
# and needed for the same reason: the chip is visible at the input field, but an
# answer travels -- §7.4 gives it an explicit way into a ticket comment, and
# there is no chip there. Reported as a count it would read as a defect; omitted
# entirely it would be the silent narrowing L7 forbids.
RSpec.describe Neo::Chat::MessageComponent, 'coverage notice (T5)', type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:chat) do
    ActsAsTenant.with_tenant(organisation) { create(:chat, :org_thread, organisation: organisation, user: user) }
  end

  def answer(coverage)
    ActsAsTenant.with_tenant(organisation) do
      build(:chatpost, chat: chat, organisation: organisation, role: 'assistant',
                       content: 'Antwort', model_used: 'gpt-x', source_coverage: coverage)
    end
  end

  # RENDERED, not called: #coverage_notice uses t(), which a ViewComponent only
  # has once it is inside the render pipeline. Calling the method directly raises
  # -- and rendering is the honest test anyway, because it asks what the reader
  # actually sees.
  def notice_for(coverage)
    ActsAsTenant.with_tenant(organisation) do
      render_inline(described_class.new(chatpost: answer(coverage), current_user: user,
                                        current_organisation: organisation))
    end
    text = page.text
    %w[Durchsucht: Searched:].each do |marker|
      line = text.lines.map(&:strip).find { |l| l.start_with?(marker) }
      return line if line
    end
    nil
  end

  # Reads the notice ELEMENT rather than a line starting with a known word. The
  # stand-alone outside sentence carries no "Durchsucht:" prefix, so #notice_for
  # above cannot see it at all -- and "cannot see it" and "was not rendered" would
  # look identical.
  def notice_element_for(coverage)
    ActsAsTenant.with_tenant(organisation) do
      render_inline(described_class.new(chatpost: answer(coverage), current_user: user,
                                        current_organisation: organisation))
    end
    page.all('[data-testid="coverage-notice"]').first&.text&.strip
  end

  it 'names the project when the narrowing was chosen' do
    expect(notice_for('searched' => 1, 'total' => 12, 'chosen' => 'Nordlicht Software'))
      .to eq('Durchsucht: nur Nordlicht Software')
  end

  it 'counts when the rights did the narrowing' do
    expect(notice_for('searched' => 3, 'total' => 12)).to eq('Durchsucht: 3 von 12 Projekten')
  end

  # The chosen sentence does NOT depend on the arithmetic. An organisation with a
  # single project would otherwise stay silent about a scope the user set, and
  # the answer would travel without it.
  it 'names the chosen project even when it is the only one' do
    expect(notice_for('searched' => 1, 'total' => 1, 'chosen' => 'Nordlicht Software'))
      .to eq('Durchsucht: nur Nordlicht Software')
  end

  it 'stays silent when nothing was narrowed' do
    expect(notice_for('searched' => 12, 'total' => 12)).to be_nil
  end

  # Rows written before T5 have no `chosen` key. They must render exactly as
  # before, not crash and not grow a sentence.
  it 'renders a pre-T5 answer unchanged' do
    expect(notice_for('searched' => 2, 'total' => 9)).to eq('Durchsucht: 2 von 9 Projekten')
  end

  # ⚠️ The third reason an answer is not simply "everything", and it arrived with
  # E3 (review of #642): the thread POINTS AT an object that lies outside what was
  # searched, and since the reach fix the assistant may read it. Without this the
  # chosen sentence would claim "nur Nordlicht" about an answer that also read a
  # ticket from somewhere else -- a small lie, but exactly the kind L7 exists to
  # forbid.
  #
  # Appended rather than a fourth full sentence: it composes with BOTH forms, and a
  # sentence per combination is how the two above start to drift apart.
  it 'says so when the subject sits outside what was searched' do
    expect(notice_for('searched' => 1, 'total' => 12, 'chosen' => 'Nordlicht Software', 'outside' => true))
      .to eq('Durchsucht: nur Nordlicht Software. Der Bezug liegt außerhalb und wurde zusätzlich gelesen.')
  end

  it 'appends it to the counted form as well' do
    expect(notice_for('searched' => 3, 'total' => 12, 'outside' => true))
      .to eq('Durchsucht: 3 von 12 Projekten. Der Bezug liegt außerhalb und wurde zusätzlich gelesen.')
  end

  # The negative half. "Appends it" is true of an implementation that appends it
  # always, and then every answer would carry a sentence about a reference that is
  # not there.
  it 'leaves it away when nothing sits outside' do
    expect(notice_for('searched' => 1, 'total' => 12, 'chosen' => 'Nordlicht Software'))
      .not_to include('außerhalb')
  end

  # ⚠️ The gap the review of #642 found, and it is reachable without a chip.
  # The model may narrow the CALL itself (get_ticket with project:), while the
  # thread points at a ticket somewhere else. GetTicket#by_id then rewrites the
  # coverage to `searched: <full reach>, outside: true` and drops `chosen` -- so
  # searched EQUALS total, the arithmetic gate fires, and the whole notice is
  # thrown away, outside flag and all. The reader is told nothing.
  #
  # `outside` is its own reason, exactly like `chosen` one cell above, and must
  # not hang on a numeric gap.
  it 'says so when nothing narrowed the search but the subject sat outside it' do
    expect(notice_element_for('searched' => 12, 'total' => 12, 'outside' => true))
      .to eq('Der Bezug liegt außerhalb des Suchbereichs und wurde zusätzlich gelesen.')
  end

  # ⚠️ A SEPARATE key, not the appended one. The appended sentence says
  # "außerhalb" / "outside it" and leans on the half before it for what "it" is.
  # Standing alone that pronoun has no antecedent, and in English it is plainly
  # broken. Two positions, two sentences.
  it 'has the stand-alone outside sentence in English too' do
    I18n.with_locale(:en) do
      expect(notice_element_for('searched' => 12, 'total' => 12, 'outside' => true))
        .to eq('The reference lies outside the searched projects and was read as well.')
    end
  end

  # The negative half, and it guards the same mistake in the other direction: a
  # version that renders the stand-alone sentence whenever the numbers are equal
  # would put it under every ordinary answer.
  it 'stays silent when nothing was narrowed and nothing sat outside' do
    expect(notice_element_for('searched' => 12, 'total' => 12)).to be_nil
  end

  it 'has the outside sentence in English too' do
    I18n.with_locale(:en) do
      expect(notice_for('searched' => 1, 'total' => 12, 'chosen' => 'Nordlicht Software', 'outside' => true))
        .to eq('Searched: Nordlicht Software only. The reference lies outside it and was read as well.')
    end
  end

  it 'has the chosen sentence in English too' do
    I18n.with_locale(:en) do
      expect(notice_for('searched' => 1, 'total' => 12, 'chosen' => 'Nordlicht Software'))
        .to eq('Searched: Nordlicht Software only')
    end
  end
end
