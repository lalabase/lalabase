# frozen_string_literal: true

require 'rails_helper'

# The ONE address of a citation's target (Feinschliff C). Two callers ask: the
# source list under an answer and the links inside the answer's prose. The
# component spec covers the rendered end of it; this pins the builder itself,
# including the cases where there is deliberately no address.
RSpec.describe Lalabase::CitationLink do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:routes) { Rails.application.routes.url_helpers }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def path(citation, project_fallback: nil)
    described_class.path_for(citation, organisation: organisation, project: project_fallback)
  end

  it 'points a ticket at its own page' do
    expect(path({ 'type' => 'ticket', 'id' => 'tid', 'project_id' => project.id }))
      .to eq(routes.organisation_project_ticket_path(organisation, project.id, 'tid'))
  end

  it 'points a COMMENT at its ticket, because a comment has no page' do
    expect(path({ 'type' => 'post', 'id' => 'pid', 'ticket_id' => 'tid', 'project_id' => project.id }))
      .to eq(routes.organisation_project_ticket_path(organisation, project.id, 'tid'))
  end

  it 'points a meeting analysis at its meeting' do
    expect(path({ 'type' => 'meeting_analysis', 'id' => 'aid', 'meeting_id' => 'mid',
                  'project_id' => project.id }))
      .to eq(routes.organisation_project_meeting_path(organisation, project.id, 'mid'))
  end

  it 'addresses a doc page by set and path, which is how the browsing route works' do
    result = path({ 'type' => 'documentation', 'id' => 'pid', 'set_id' => 'sid',
                    'page' => 'guide/intro.md', 'project_id' => project.id })

    expect(result).to include('set_id=sid')
    expect(result).to include('page=guide%2Fintro.md')
  end

  it 'reopens the time list under the frozen filters for a report' do
    result = path({ 'type' => 'time_report', 'id' => 'x', 'project_id' => project.id,
                    'filters' => { 'start_date' => '2026-05-01' } })

    # The organisation list with the project as a filter: the project's own
    # times page is gone (doc/zeiten_eine_liste_plan.md).
    expect(result).to include('/time-tracking?')
    expect(result).to include("project_id_filter=#{project.id}")
    expect(result).to include('start_date=2026-05-01')
  end

  it 'falls back to the caller project only when the citation carries none' do
    other = create(:project, organisation: organisation)

    expect(path({ 'type' => 'ticket', 'id' => 'tid' }, project_fallback: other))
      .to eq(routes.organisation_project_ticket_path(organisation, other, 'tid'))
    # The citation's OWN project wins: an org-wide answer cites across projects.
    expect(path({ 'type' => 'ticket', 'id' => 'tid', 'project_id' => project.id }, project_fallback: other))
      .to eq(routes.organisation_project_ticket_path(organisation, project.id, 'tid'))
  end

  # Positive iteration, house style (the same shape the source list pins its icons
  # and labels with): a new content type must not reach the citation shapes without
  # an address, or the source row and every mention in the prose silently go quiet.
  it 'has an address for EVERY content type' do
    Lalabase::Citations::CONTENT_TYPES.each do |type|
      citation = { 'type' => type, 'id' => 'x', 'ticket_id' => 'x', 'meeting_id' => 'x',
                   'set_id' => 'sid', 'page' => 'guide/intro.md', 'project_id' => project.id,
                   'filters' => {} }
      expect(path(citation)).to be_present, "#{type} leads nowhere"
    end
  end

  # The product layer has its own address rule (no project, no organisation), so it is iterated
  # on its own rather than squeezed into the content fixture above.
  it 'has an address for EVERY product type' do
    Lalabase::Citations::PRODUCT_TYPES.each do |type|
      citation = { 'type' => type, 'id' => 'guides/features/time-tracking', 'source' => 'help' }
      expect(path(citation)).to be_present, "#{type} leads nowhere"
    end
  end

  # Lalabase's own help (doc/product_knowledge_plan.md, S2) lives outside every organisation
  # and project, under /hilfe. The project fallback must neither give it a link nor take one away.
  describe 'a help page' do
    let(:help) { { 'type' => 'help_page', 'source' => 'help', 'id' => 'guides/features/time-tracking' } }

    it 'points at /hilfe by slug, without any project to hang the route on' do
      expect(path(help)).to eq('/hilfe/guides/features/time-tracking')
    end

    it 'ignores a project the caller offers, because the help has none' do
      expect(path(help, project_fallback: project)).to eq('/hilfe/guides/features/time-tracking')
    end

    context 'on an instance that does not carry the handbook' do
      it 'points at the public documentation, so the citation leads somewhere' do
        without_docs_catalogue do
          expect(path(help)).to eq('https://lalabase.com/docs/de/guides/features/time-tracking')
        end
      end

      it 'takes the language the page was READ in, not the ambient one' do
        # This renders again inside the streaming job, where nothing sets
        # I18n.locale and the app default would win. An English reader's
        # streamed citation would then point at the German page while the same
        # citation on page load pointed at the English one.
        without_docs_catalogue do
          expect(path(help.merge('locale' => 'en')))
            .to eq('https://lalabase.com/docs/en/guides/features/time-tracking')
        end
      end

      it 'stays on the German page when the citation says so, whatever I18n says' do
        without_docs_catalogue do
          I18n.with_locale(:en) do
            expect(path(help.merge('locale' => 'de')))
              .to eq('https://lalabase.com/docs/de/guides/features/time-tracking')
          end
        end
      end
    end

    # Branches on the source, so the news (S3) get their own address instead of the help's.
    it 'gives none for a source it does not know, or without a slug' do
      expect(path(help.merge('source' => 'news'))).to be_nil
      expect(path(help.except('source'))).to be_nil
      expect(path(help.merge('id' => ''))).to be_nil
    end
  end

  # People S3: the directory belongs to the organisation, not to a project, so the project
  # fallback must neither give a person its link nor take it away.
  describe 'a person' do
    let(:contact) { { 'type' => 'person', 'area' => 'people', 'id' => 'pid', 'name' => 'Doris Dienstleister' } }
    let(:member) { { 'type' => 'person', 'area' => 'people', 'id' => 'uid', 'member_id' => 'uid', 'name' => 'Carl' } }

    it 'opens a contact on the people page by its row' do
      expect(path(contact)).to eq(routes.organisation_people_path(organisation, person_id: 'pid'))
    end

    it 'opens a member on the people page by the account' do
      expect(path(member)).to eq(routes.organisation_people_path(organisation, member_id: 'uid'))
    end

    it 'needs no project and ignores one the caller offers' do
      expect(path(contact, project_fallback: project))
        .to eq(routes.organisation_people_path(organisation, person_id: 'pid'))
    end

    it 'gives none without an id' do
      expect(path(contact.merge('id' => ''))).to be_nil
    end
  end

  it 'points a note, a document and a meeting at their own pages' do
    { 'note' => :organisation_project_note_path,
      'document' => :organisation_project_document_path,
      'meeting' => :organisation_project_meeting_path }.each do |type, route|
      expect(path({ 'type' => type, 'id' => 'rid', 'project_id' => project.id }))
        .to eq(routes.public_send(route, organisation, project.id, 'rid'))
    end
  end

  # Category 7 (JSONB): WHICH key form this side reads is a contract.
  # `Citations.target_of` takes both, because it is asked on the producer AND the
  # render side; this builder is fed exclusively from JSONB and therefore reads
  # strings. The cell pins that, so the asymmetry is visible instead of a silent
  # surprise.
  describe 'the key flavour it reads' do
    let(:string_keyed) { { 'type' => 'ticket', 'id' => 'tid', 'project_id' => project.id } }
    let(:symbol_keyed) { { type: 'ticket', id: 'tid', project_id: project.id } }

    it 'reads the string keys JSONB hands back' do
      expect(path(string_keyed)).to be_present
    end

    it 'reads NO symbol keys, unlike Citations.target_of next to it' do
      expect(Lalabase::Citations.target_of(symbol_keyed)).to be_present
      expect(path(symbol_keyed)).to be_nil
    end
  end

  describe 'no address at all' do
    it 'gives none without an organisation' do
      expect(described_class.path_for({ 'type' => 'ticket', 'id' => 'tid', 'project_id' => project.id },
                                      organisation: nil)).to be_nil
    end

    it 'gives none without any project to hang the route on' do
      expect(path({ 'type' => 'ticket', 'id' => 'tid' })).to be_nil
    end

    it 'gives none for the code layer and for an unknown type' do
      %w[vision capability symbol something_new].each do |type|
        expect(path({ 'type' => type, 'id' => 'x', 'project_id' => project.id })).to be_nil
      end
    end

    it 'gives none when the id the address hangs on is missing' do
      expect(path({ 'type' => 'ticket', 'project_id' => project.id })).to be_nil
      expect(path({ 'type' => 'post', 'id' => 'pid', 'project_id' => project.id })).to be_nil
      expect(path({ 'type' => 'documentation', 'id' => 'p', 'set_id' => 'sid',
                    'project_id' => project.id })).to be_nil
    end

    it 'gives none for a non-Hash (defense in depth: this reads JSONB)' do
      expect(described_class.path_for('not a hash', organisation: organisation)).to be_nil
    end
  end
end
