# frozen_string_literal: true

require 'rails_helper'

# A suggestion run keeps its post optional (belongs_to :chatpost, optional: true),
# so the partial must survive a run that has none: the post can be gone, or
# invisible to the tenant that renders. Until 19.09.2026 the frame tag read
# run.chatpost.chat regardless and took the whole page down with it, which showed
# up as an intermittently red system spec rather than as the defect it is.
RSpec.describe 'neo/chat/_ticket_suggestion_run', type: :view do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:meeting) { in_org { create(:meeting, organisation: organisation, project: project, creator: user) } }
  let(:project) { in_org { create(:project, organisation: organisation) } }

  def in_org(&)
    ActsAsTenant.with_tenant(organisation, &)
  end

  def build_run(chatpost:)
    in_org do
      MeetingTicketSuggestionRun.create!(organisation: organisation, meeting: meeting, project_id: project.id,
                                         chatpost: chatpost, meeting_title: meeting.title,
                                         project_title: project.name, job_id: SecureRandom.uuid,
                                         status: 'queued', instruction: 'Aufgaben ableiten')
    end
  end

  def render_run(run)
    in_org { render partial: 'neo/chat/ticket_suggestion_run', locals: { run: run, user: user } }
    Nokogiri::HTML.fragment(rendered)
  end

  context 'without a post' do
    it 'renders the frame instead of raising' do
      run = build_run(chatpost: nil)

      frame = render_run(run).at_css('turbo-frame')

      expect(frame['id']).to eq("meeting_ticket_suggestion_run_#{run.id}")
      expect(frame.text).to include(I18n.t('assistant_suggestions.unavailable'))
    end

    # Nothing to poll, and a controller without an address would fetch the page
    # it sits on when something forces a refresh.
    it 'attaches no controller, so nothing polls an address that does not exist' do
      frame = render_run(build_run(chatpost: nil)).at_css('turbo-frame')

      expect(frame['data-controller']).to be_nil
      expect(frame.to_html).not_to include('assistant_suggestion_result_url_value')
    end
  end

  # Keeps the two examples above honest: a partial that rendered a bare frame for
  # everything would pass them and serve nobody.
  context 'with a post' do
    it 'wires the controller to the run of that chat' do
      chat = in_org { create(:chat, organisation: organisation, user: user) }
      post = in_org { create(:chatpost, chat: chat, user: user, organisation: organisation) }

      frame = render_run(build_run(chatpost: post)).at_css('turbo-frame')

      expect(frame['data-controller']).to eq('assistant-suggestion-result')
      expect(frame['data-assistant-suggestion-result-url-value']).to include(chat.id)
    end
  end
end
