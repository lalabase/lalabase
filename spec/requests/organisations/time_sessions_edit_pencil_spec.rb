# frozen_string_literal: true

require 'rails_helper'

# What:  The pencil of a booking in the time list opens the edit form the same way on the
#        phone's card and on the desk's line: a button of time-session-popup, which loads the
#        form into an overlay (lib/time_session_modal.js).
# Type:  Request spec over the rendered index. It reads the markup;
#        spec/system/time_list_phone_edit_spec.rb taps the pencil on a phone.
# Why:   The phone's pencil was a link to time_sessions#edit inside the time list's frame.
#        Turbo loaded the answer into that frame, the answer carried no such frame, and the list
#        turned into "Content missing" (lalabase/lalabase#263).
RSpec.describe 'Organisations::TimeSessions edit pencil', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:project) { with_tenant { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant do
      create(:membership, user: admin, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
    sign_in admin
    Prosopite.pause
  end

  # After the membership: the factory makes its creator a plain member otherwise.
  let!(:booking) do
    with_tenant do
      create(:time_session, organisation: organisation, project: project, creator: admin,
                            duration: 60, occurred_on: Date.current)
    end
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&)
    ActsAsTenant.with_tenant(organisation, &)
  end

  def list_frame
    get organisation_time_sessions_path(organisation)
    expect(response).to have_http_status(:ok)
    frame = Nokogiri::HTML(response.body).at_css('turbo-frame#time_sessions_list_frame')
    expect(frame).to be_present
    frame
  end

  def pencils(scope)
    scope.css(%(button[data-time-session-id="#{booking.id}"][data-action~="click->time-session-popup#editTimeSession"]))
  end

  # The phone's card sits in the md:hidden half of the list, the desk's line in the other.
  def on_phone?(element)
    element.ancestors('[class~="md:hidden"]').any?
  end

  it 'gives the phone card the pencil of the desk line, inside time-session-popup' do
    found = pencils(list_frame)

    expect(found.map { |pencil| on_phone?(pencil) }).to contain_exactly(true, false)
    found.each do |pencil|
      popup = pencil.ancestors('[data-controller~="time-session-popup"]').first
      expect(popup&.[]('data-project-id')).to eq(project.id)
      expect(pencil['data-context']).to eq('index_page')
    end
  end

  it 'leaves no link to the edit form inside the list frame' do
    frame = list_frame
    expect(pencils(frame)).to be_present

    expect(frame.css(%(a[href*="/time_sessions/#{booking.id}/edit"]))).to be_empty
  end
end
