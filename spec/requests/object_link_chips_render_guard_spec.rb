# frozen_string_literal: true

require 'rails_helper'

# What:  ObjectLinkRenderGuard (config/initializers/object_link_render_guard.rb): no object
#        chip in a render that is not the page of the signed-in reader.
# Type:  Rendering spec in the controller of a signed-in reader.
# Why:   ActionText renders its layout through the controller of the CURRENT request
#        (ActionText::Content.with_renderer). A Turbo broadcast rendered during that request
#        (ApplicationController.render) would therefore see the request's user as the
#        reader, and a chip would carry a title that user may read to every subscriber of
#        the stream. The guard switches the chips off there. A mail needs no guard (ActionText
#        renders through the mailer, which has no reader); the example holds that, and that
#        the layout still renders in a mailer, which lacks the app's helpers.
RSpec.describe 'Object chips outside the reader page', :ci_guard, :object_link_render do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:reader) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:target) { create(:ticket, project: project, organisation: organisation, title: 'Readable to the actor only') }
  let(:address) { "http://www.example.com/org/#{organisation.id}/projects/#{project.id}/tickets/#{target.id}" }
  let(:comment) do
    create(:post, ticket: ticket, user: reader, content: %(<div><a href="#{address}">#{address}</a></div>))
  end
  let(:template) { { inline: '<%= post.content %>', locals: { post: comment } } }

  around { |example| Prosopite.pause { example.run } }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: reader, organisation: organisation)
    create(:project_permission, user: reader, project: project, tickets_access: :read_write)
  end

  after { ActsAsTenant.current_tenant = nil }

  it "shows the chip on the reader's own page (the control)" do
    expect(render_as_reader(reader_controller(reader), **template)).to include('Readable to the actor only')
  end

  it 'shows no chip in a broadcast rendered during the request' do
    controller = reader_controller(reader)

    html = ActionText::Content.with_renderer(controller) { ApplicationController.render(**template) }

    expect(html).to include(address)
    expect(html).not_to include('Readable to the actor only')
    expect(html).not_to include('object-chip')
  end

  it 'shows no chip in a mail rendered during the request' do
    stub_const('ObjectChipProbeMailer', Class.new(ApplicationMailer) do
      def probe
        @post = params[:post]
        mail(to: 'someone@example.com', subject: 'probe') do |format|
          format.html { render inline: '<%= @post.content %>' }
        end
      end
    end)

    html = ActionText::Content.with_renderer(reader_controller(reader)) do
      ObjectChipProbeMailer.with(post: comment).probe.message.body.to_s
    end

    expect(html).to include(address)
    expect(html).not_to include('Readable to the actor only')
  end
end
