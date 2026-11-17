# frozen_string_literal: true

require 'rails_helper'

# What:  ObjectLinksHelper#object_link_chips, the call in the ActionText layout.
# Type:  Helper spec.
# Why:   A link is always a correct answer, a chip only an improvement on it. Without a
#        reader, without the page's organisation as tenant, inside a broadcast and on any
#        error the text must come out exactly as it went in.
RSpec.describe ObjectLinksHelper, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:reader) { create(:user) }
  let(:target) { create(:ticket, project: project, organisation: organisation, title: 'Visible target') }
  let(:address) { "http://test.host/org/#{organisation.id}/projects/#{project.id}/tickets/#{target.id}" }
  # As the layout's yield hands it over: a SafeBuffer of the sanitised content.
  let(:html) { ActionController::Base.helpers.sanitize(%(<div><a href="#{address}">#{address}</a></div>)) }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      create(:membership, user: reader, organisation: organisation)
      create(:project_permission, user: reader, project: project, tickets_access: :read_write)
    end
    signed_in = reader
    helper.define_singleton_method(:current_user) { signed_in }
    Current.reset
  end

  after do
    ActsAsTenant.current_tenant = nil
    Current.reset
  end

  it 'draws the chip for the signed-in reader (the control)' do
    expect(helper.object_link_chips(html)).to include('Visible target')
  end

  it 'returns the text as it was without a reader' do
    helper.define_singleton_method(:current_user) { raise 'no warden here' }

    expect(helper.object_link_chips(html)).to eq(html)
  end

  it 'returns the text as it was without a tenant' do
    text = html
    ActsAsTenant.current_tenant = nil

    expect(helper.object_link_chips(text)).to eq(text)
  end

  it 'returns the text as it was inside a broadcast render' do
    result = ObjectLinkRenderGuard.suppress { helper.object_link_chips(html) }

    expect(result).to eq(html)
  end

  context 'when something fails' do
    around do |example|
      described_class.tolerate_errors = true
      example.run
    ensure
      described_class.tolerate_errors = nil
    end

    it 'returns the text as it was and reports the error' do
      allow(ObjectLinks::Address).to receive(:parse).and_raise(ArgumentError, 'broken')
      allow(Rails.error).to receive(:report)

      expect(helper.object_link_chips(html)).to eq(html)
      expect(Rails.error).to have_received(:report).with(an_instance_of(ArgumentError), hash_including(handled: true))
    end
  end

  it 're-raises in development and test, so a broken chip does not hide behind its fallback' do
    allow(ObjectLinks::Address).to receive(:parse).and_raise(ArgumentError, 'broken')

    expect { helper.object_link_chips(html) }.to raise_error(ArgumentError, 'broken')
  end
end
