# frozen_string_literal: true

require 'rails_helper'

# What:  The cached comment partial (shared/_cached_post, keyed by
#        NeoPostComponent#cache_key_with_version) and the object chips inside it.
# Type:  Rendering spec with a real cache store, in the controller of a signed-in reader.
# Why:   A comment is cached for 30 minutes per reader. A chip names its target as the
#        reader may see it NOW: a renamed target must show its new name, and a reader who
#        lost the right must not see the old one from the cache. The key carries a digest
#        of the RENDERED content, chips included; this spec holds that it is enough.
#        (The partial is rendered by no page today, organisations/tickets/_post_new has no
#        caller; the timeline renders the component uncached. The spec holds the cache for
#        the day it comes back.)
RSpec.describe 'Object chips in a cached comment', :ci_guard, :object_link_render do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:reader) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:target) { create(:ticket, project: project, organisation: organisation, title: 'Old target name') }
  let(:address) { "http://www.example.com/org/#{organisation.id}/projects/#{project.id}/tickets/#{target.id}" }
  let(:comment) do
    create(:post, ticket: ticket, user: reader, content: %(<div><a href="#{address}">#{address}</a></div>))
  end

  around do |example|
    original_store = ActionController::Base.cache_store
    original_flag = ActionController::Base.perform_caching
    ActionController::Base.cache_store = ActiveSupport::Cache::MemoryStore.new
    ActionController::Base.perform_caching = true
    Prosopite.pause { example.run }
  ensure
    ActionController::Base.cache_store = original_store
    ActionController::Base.perform_caching = original_flag
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: reader, organisation: organisation)
    create(:project_permission, user: reader, project: project, tickets_access: :read_write)
  end

  after { ActsAsTenant.current_tenant = nil }

  # One request of the reader: a fresh controller and a fresh request memo each time.
  def cached_comment
    Current.reset
    render_as_reader(reader_controller(reader), partial: 'shared/cached_post',
                                                locals: { post: comment.reload, current_user: reader,
                                                          current_organisation: organisation })
  end

  # The control: without it, the two examples below would pass with no cache at all.
  it 'serves the second render from the cache while nothing changed' do
    store = ActionController::Base.cache_store
    allow(store).to receive(:write).and_call_original

    expect(cached_comment).to include('Old target name')
    expect(cached_comment).to include('Old target name')

    expect(store).to have_received(:write).once
  end

  it 'shows the new name after the target is renamed' do
    expect(cached_comment).to include('Old target name')

    target.update!(title: 'New target name')
    html = cached_comment

    expect(html).to include('New target name')
    expect(html).not_to include('Old target name')
  end

  it 'shows the plain link once the reader lost the right' do
    expect(cached_comment).to include('Old target name')

    ProjectPermission.find_by!(user: reader, project: project).update!(tickets_access: :no_access)
    html = cached_comment

    expect(html).not_to include('Old target name')
    expect(html).not_to include('object-chip')
    expect(html).to include(address)
  end
end
