# frozen_string_literal: true

require 'rails_helper'

# What: the files of the people above the organisations (GET /people), named in ONE list,
#       never lift the tenant.
# Why:  the feature shows the people of several organisations on one page. It reads each
#       organisation under ActsAsTenant.with_tenant, through People::Lookup, and shows only
#       what that read returned (People::AcrossOrganisations). A read with the tenant
#       lifted would need a rights rule of its own for every organisation at once, and one
#       forgotten condition would show an organisation's people to somebody without the
#       people right there. Merging rows (the two actors, their controller, the two models)
#       and taking a contact over into another organisation stand in the list as well, and
#       so does the card of one person (People::MergedCard and the templates of the lane).
# Not seen: a file of the feature that is missing from the list, and a lift reached
#       through another object (a helper of another area that lifts the tenant itself).
#       Those are for the reader of the diff.
RSpec.describe 'The people above the organisations never lift the tenant' do
  feature_files = %w[
    app/controllers/all_people_controller.rb
    app/controllers/all_people/merges_controller.rb
    app/controllers/organisations/person_takeovers_controller.rb
    app/helpers/all_people_helper.rb
    app/javascript/controllers/all_people_filter_controller.js
    app/javascript/controllers/all_people_merge_controller.js
    app/javascript/controllers/person_takeover_modal_controller.js
    app/models/person_group.rb
    app/models/person_group_entry.rb
    app/services/actors/merge_people.rb
    app/services/actors/split_person.rb
    app/services/actors/take_over_person.rb
    app/services/people/across_organisations.rb
    app/services/people/merged_card.rb
    app/services/people/lookup.rb
    app/services/people/directory.rb
    app/services/people/contacts.rb
    app/views/all_people/index.html.erb
    app/views/all_people/_tools.html.erb
    app/views/all_people/_results.html.erb
    app/views/all_people/_row.html.erb
    app/views/all_people/_lane.html.erb
    app/views/all_people/_card.html.erb
    app/views/all_people/_card_head.html.erb
    app/views/organisations/person_takeovers/_dialog.html.erb
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
    expect(files).to include('app/services/people/across_organisations.rb', 'app/services/people/merged_card.rb',
                             'app/controllers/all_people_controller.rb')
  end

  it 'names every controller of the page and the writes behind them' do
    controllers = Rails.root.glob('app/controllers/all_people/**/*.rb').map { |path| path.relative_path_from(Rails.root).to_s }

    expect(controllers).not_to be_empty
    expect(controllers - files).to be_empty
    expect(files).to include('app/services/actors/merge_people.rb', 'app/services/actors/split_person.rb',
                             'app/services/actors/take_over_person.rb')
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

# What: the two models of a merge (the tables person_groups and person_group_entries) are
#       named by a CLOSED list of files, and by no other code of the application.
# Why:  a merge is one person's private note that rows of different organisations are the
#       same human. An organisation must never learn that somebody knows its person
#       elsewhere. So nothing an organisation answers with may read these tables: not its
#       people page, not the assistant's tools, not MCP, not REST, not the admin backend,
#       not the search. The list below is every reader and writer there is, each with its
#       reason; a new name anywhere else is red until somebody decided that it belongs.
# Not seen: a read that names neither model nor table (a constant held in a variable, an
#       association reached through another model: there is none, the models declare no
#       has_many on User or Organisation), and what a file of the list does with them.
RSpec.describe 'The merges of people are named only by the files of the feature' do
  readers = {
    'app/models/person_group.rb' => 'the model',
    'app/models/person_group_entry.rb' => 'the model, and the one rule that holds an entry against a directory',
    'app/services/actors/merge_people.rb' => 'writes a merge',
    'app/services/actors/split_person.rb' => 'deletes a merge',
    'app/services/people/across_organisations.rb' => "reads the viewer's own merges for the list above the organisations",
    'app/models/concerns/person_link_release.rb' => 'a member leaves: the entries by account follow the row',
    'app/models/concerns/personal_data_erasure.rb' => 'an account is erased: its merges and the entries that name it go',
    'app/services/user_data_exports/registry.rb' => "the owner's export, and the reason person_groups is not a source"
  }.freeze

  # Code of the application: what runs. The cards beside it (CLAUDE.md) describe the rule
  # in words and are no reader.
  roots = %w[app lib config].freeze
  code = /\.(rb|erb|rake|js|ya?ml|css|jbuilder)\z/
  name = /PersonGroup|person_group/

  # Every path => text of the application's code that names a merge. Takes the texts as an
  # argument so that the rule itself can be shown a file that breaks it.
  naming = ->(texts) { texts.select { |_path, text| text.match?(name) }.keys.sort }

  texts = roots.flat_map { |root| Rails.root.glob("#{root}/**/*") }
               .select { |path| path.file? && path.to_s.match?(code) }
               .to_h { |path| [path.relative_path_from(Rails.root).to_s, path.read] }

  it 'reads the code of the application' do
    expect(texts.size).to be > 1000
    expect(texts.keys).to include('app/services/lalabase/tools/find_people.rb', 'app/controllers/api/v1/people_controller.rb',
                                  'app/controllers/organisations/people_controller.rb', 'app/services/combined_search_service.rb')
  end

  it 'finds exactly the files of the list' do
    unlisted = naming.call(texts) - readers.keys
    stale = readers.keys - naming.call(texts)

    expect(unlisted).to be_empty, <<~MSG
      #{unlisted.join(', ')} names a merge of the people above the organisations (PersonGroup,
      PersonGroupEntry or their tables) and is not in the list of this spec.
      A merge is its owner's private note; an organisation must never learn of it. Nothing an
      organisation answers with may read these tables. If the file belongs to the feature
      and shows a merge to its owner only, add it to the list with its reason.
    MSG
    expect(stale).to be_empty, "listed, but names no merge any more (drop the entry): #{stale.join(', ')}"
  end

  it 'gives every entry of the list a reason' do
    expect(readers.values).to all(be_present)
  end

  # The rule shown a file that breaks it: the assistant's people tool with one line that
  # reads the merges. Without this the list could match nothing and stay green.
  it "is red when the assistant's people tool names a merge" do
    path = 'app/services/lalabase/tools/find_people.rb'
    ['PersonGroup.where(owner_id: 1)', 'PersonGroupEntry.count', 'FROM person_group_entries'].each do |line|
      probe = texts.merge(path => "#{texts.fetch(path)}\n# #{line}\n")

      expect(naming.call(probe) - readers.keys).to eq([path]), line
    end
    expect(naming.call(texts)).not_to include(path)
  end

  it 'keeps the surfaces of an organisation out of the list' do
    surfaces = %r{\Aapp/(services/lalabase|services/search|controllers/(api|admin|organisations)|views/organisations|helpers)/}

    expect(readers.keys.grep(surfaces)).to be_empty
  end
end
