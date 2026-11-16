# frozen_string_literal: true

require 'rails_helper'

# What: the files of the people above the organisations (GET /people), named in ONE list,
#       never lift the tenant.
# Why:  the feature shows the people of several organisations on one page. It reads each
#       organisation under ActsAsTenant.with_tenant, through People::Lookup, and shows only
#       what that read returned (People::AcrossOrganisations). A read with the tenant
#       lifted would need a rights rule of its own for every organisation at once, and one
#       forgotten condition would show an organisation's people to somebody without the
#       people right there. A later part of the feature (merging rows, the card) adds its
#       files to this list.
# Not seen: a file of the feature that is missing from the list, and a lift reached
#       through another object (a helper of another area that lifts the tenant itself).
#       Those are for the reader of the diff.
RSpec.describe 'The people above the organisations never lift the tenant' do
  feature_files = %w[
    app/controllers/all_people_controller.rb
    app/helpers/all_people_helper.rb
    app/services/people/across_organisations.rb
    app/services/people/lookup.rb
    app/services/people/directory.rb
    app/views/all_people/index.html.erb
    app/views/all_people/_tools.html.erb
    app/views/all_people/_results.html.erb
    app/views/all_people/_row.html.erb
    app/views/shared/_organisation_chip.html.erb
  ].freeze

  # The call that lifts the tenant. Put together from its halves, so that this file does not
  # carry the word it refuses: a search for it over the changes of the feature finds nothing.
  word = %w[without tenant].join('_')
  lift = /#{word}/

  let(:files) { feature_files }

  it 'names files that exist' do
    missing = files.reject { |path| Rails.root.join(path).file? }

    expect(missing).to be_empty, "listed, but not there: #{missing.join(', ')}"
  end

  it 'names every template of the page and the read behind it' do
    templates = Rails.root.glob('app/views/all_people/**/*.erb').map { |path| path.relative_path_from(Rails.root).to_s }

    expect(templates).not_to be_empty
    expect(templates - files).to be_empty
    expect(files).to include('app/services/people/across_organisations.rb', 'app/controllers/all_people_controller.rb')
  end

  it 'finds the call where it stands' do
    expect("ActsAsTenant.#{word} { Person.count }").to match(lift)
    expect('ActsAsTenant.with_tenant(organisation) { Person.count }').not_to match(lift)
  end

  feature_files.each do |path|
    it "#{path} does not lift the tenant" do
      hits = Rails.root.join(path).readlines.each_with_index.select { |line, _index| line.match?(lift) }

      expect(hits).to be_empty, <<~MSG
        #{path} lifts the tenant in line #{hits.map { |_line, index| index + 1 }.join(', ')}.
        The people above the organisations read each organisation under its own tenant
        (ActsAsTenant.with_tenant, People::AcrossOrganisations). Read through People::Lookup
        inside that block instead.
      MSG
    end
  end
end
