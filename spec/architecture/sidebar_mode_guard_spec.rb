# frozen_string_literal: true

require 'rails_helper'

# What: every page of the application outside /org/ belongs to the level above
#       the organisations or to the account (navigation plan D4), through closed lists:
#       NavigationHelper::LEVEL_PAGES, NavigationHelper::ACCOUNT_PAGES and, here, the pages
#       that show no sidebar at all.
# Why:  the sidebar's middle is chosen by NavigationHelper.sidebar_mode_for. A new page
#       outside an organisation that is in none of the lists would get a sidebar by accident
#       (the level's), and an account page missing from ACCOUNT_PAGES would lose its list,
#       its marked row and its way back. A new page is one entry in one list.
# Not seen: a page under /org/ that runs without an organisation. The one known is the
#       acceptance of an invitation (Organisations::AcceptInvitationsController), which shows
#       a signed-in person the level, as any page outside an organisation.
RSpec.describe 'Every page outside an organisation has a sidebar mode', type: :helper do
  # Controllers of a GET route outside /org/ that show no sidebar of the application, with
  # the reason. Closed: an entry for a controller no route names any more is red too.
  pages_without_sidebar = {
    'legal_pages' => 'the instance legal pages render the sessionless layout',
    'root' => 'redirects: to the home of the signed-in person, else to the sign-in',
    'session_touch' => 'answers JSON for the session timer, no page',
    'confirmations' => 'Devise, the pages without a session (application_auth)',
    'passwords' => 'Devise, the pages without a session (application_auth)',
    'sessions' => 'Devise, the sign-in (its own layout)',
    'signup_handoffs' => 'redirects after the website signup, no page',
    'unlocks' => 'Devise, the pages without a session (application_auth)'
  }.freeze

  let(:no_sidebar) { pages_without_sidebar }

  # Every controller_name with a GET route outside an organisation, the admin area and the
  # APIs whose controller is a controller of the application (ApplicationController).
  let(:outside_controllers) do
    Rails.application.eager_load!
    Rails.application.routes.routes.filter_map do |route|
      next unless route.verb.to_s.include?('GET') && route.defaults[:controller]
      next if route.path.spec.to_s.start_with?('/org/', '/admin', '/api', '/rails', '/cable')

      klass = "#{route.defaults[:controller].camelize}Controller".safe_constantize
      route.defaults[:controller].split('/').last if klass && klass < ApplicationController
    end.uniq.sort
  end

  let(:level) { NavigationHelper::LEVEL_PAGES.keys }
  let(:account) { NavigationHelper::ACCOUNT_PAGE_CONTROLLERS }

  it 'finds the pages it guards' do
    expect(outside_controllers).to include('organisations', 'all_inboxes', 'registrations', 'user_preferences')
  end

  it 'puts every such page in exactly one list: the level, the account or no sidebar' do
    unplaced = outside_controllers - level - account - no_sidebar.keys
    expect(unplaced).to be_empty, <<~MSG
      These controllers have a page outside an organisation and belong to no list: #{unplaced.join(', ')}.
      An account page goes into NavigationHelper::ACCOUNT_PAGES, a page of the level into
      NavigationHelper::LEVEL_PAGES, a page without the application's sidebar into no_sidebar here,
      with its reason.
    MSG
    expect(level & account).to be_empty
    expect((level | account) & no_sidebar.keys).to be_empty
  end

  it 'keeps no stale entry in the lists' do
    expect(account - outside_controllers).to be_empty
    expect(level - outside_controllers).to be_empty
    expect(no_sidebar.keys - outside_controllers).to be_empty
  end

  it 'gives every page of the account the account sidebar and every page of the level the level sidebar' do
    account.each do |name|
      expect(NavigationHelper.sidebar_mode_for(controller_name: name, organisation: nil, signed_in: true)).to eq(:account), name
    end
    level.each do |name|
      expect(NavigationHelper.sidebar_mode_for(controller_name: name, organisation: nil, signed_in: true)).to eq(:level), name
    end
  end
end
