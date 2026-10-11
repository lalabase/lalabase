# frozen_string_literal: true

require 'rails_helper'

# What: Overview::RecentNotificationsComponent — the latest-notifications list widget.
# Type: Component spec (always-renders + route-free empty state + limit logic; populated list with
#       links -> covered by the briefings request spec).
# Why:  Pins that it always renders (recipient-scoped) with an in-card empty state, and the
#       configurable limit (shared sanitise-or-default).
RSpec.describe Overview::RecentNotificationsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def component(limit: nil)
    described_class.new(organisation: organisation, user: user,
                        briefing: instance_double(Dashboard::DailyBriefing), limit: limit)
  end

  it 'always renders (recipient-scoped)' do
    expect(component.should_render?).to be true
  end

  it 'shows the empty state when there are no notifications' do
    render_inline(component)
    expect(page).to have_text(I18n.t('overview.notifications.empty'))
  end

  it 'honours a whitelisted item limit' do
    expect(component(limit: '15').send(:effective_limit)).to eq(15)
  end

  # The "who · where" sub-line is the actionability fix: a bare "Kommentar hinzugefügt" becomes
  # "<actor> · <project>". Each part drops out when absent (system events have no actor; some events
  # carry no project), so the dot never dangles.
  describe '#context_label' do
    it 'joins actor and project with a dot separator' do
      # Render first: since S3 the actor name resolves through
      # helpers.viewer_display_name, and #helpers only exists once the
      # component entered the render pipeline.
      rendered_component = component
      render_inline(rendered_component)
      notification = instance_double(Notification, actor: instance_double(User, display_name: 'Maria M.'),
                                                   project: instance_double(Project, name: 'Projekt Alpha'))
      expect(rendered_component.send(:context_label, notification)).to eq('Maria M. · Projekt Alpha')
    end

    it 'drops the actor for a system event (no actor), keeping just the project' do
      notification = instance_double(Notification, actor: nil,
                                                   project: instance_double(Project, name: 'Projekt Alpha'))
      expect(component.send(:context_label, notification)).to eq('Projekt Alpha')
    end

    it 'is blank when neither actor nor project is present (no dangling separator)' do
      notification = instance_double(Notification, actor: nil, project: nil)
      expect(component.send(:context_label, notification)).to eq('')
    end
  end
end
