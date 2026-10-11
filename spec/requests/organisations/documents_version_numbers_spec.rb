# frozen_string_literal: true

require 'rails_helper'

# What: the version number in the document frame (doc/dokumentansicht_plan.md, S1).
# Type: request spec on the knowledge lane's document root.
# Why: "v2" is the identifier one talks about; the file name repeats. The row
#   shows it once numbered, newest first, the current one weighted; a version
#   without a number (the stock before its task) shows none rather than a lie.
RSpec.describe 'Document version numbers', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def page = Capybara.string(response.body)

  def document_with(numbers)
    Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      versions = numbers.each_with_index.map do |number, i|
        create(:document_version, document: doc, organisation: organisation, number: number, title: "Stand #{i + 1}",
                                  created_at: (numbers.size - i).days.ago)
      end
      doc.update!(current_version: versions.last)
      doc
    end
  end

  it 'shows the number on every numbered row, newest first, the current one weighted' do
    document = document_with([1, 2])
    get organisation_project_knowledge_index_path(organisation, project, document_id: document.id)

    labels = page.all('[data-version-number]', visible: :all).map(&:text)
    expect(labels).to eq(%w[v2 v1])
    current = page.find("##{ActionView::RecordIdentifier.dom_id(document.current_version)}_document_versions [data-version-number]", visible: :all)
    expect(current[:class]).to include('font-semibold')
  end

  it 'shows no number for a version the task has not reached yet' do
    document = document_with([nil])
    get organisation_project_knowledge_index_path(organisation, project, document_id: document.id)

    expect(page).to have_no_css('[data-version-number]', visible: :all)
  end
end
