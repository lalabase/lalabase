# frozen_string_literal: true

require 'rails_helper'

# Actors::CloneSmartFolder deep-copies a folder + its rule tree into a new,
# private folder owned by the acting user; shares are never carried over.
RSpec.describe Actors::CloneSmartFolder do
  let(:organisation) { create(:organisation) }
  let(:owner) { create(:user) }
  let(:cloner) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:source) do
    folder = create(:smart_folder, user: owner, organisation: organisation, project: project,
                                   target_object_type: 'Ticket', is_public: true,
                                   public_access_level: 2, description: 'Quelle')
    group1 = create(:smart_folder_rule_group, smart_folder: folder, name: 'G1', position: 1)
    group2 = create(:smart_folder_rule_group, smart_folder: folder, name: 'G2', position: 2)
    create(:smart_folder_rule, smart_folder_rule_group: group1, field: 'title', operator: 'contains', value: 'a', position: 1)
    create(:smart_folder_rule, smart_folder_rule_group: group1, field: 'title', operator: 'contains', value: 'b', position: 2)
    create(:smart_folder_rule, smart_folder_rule_group: group2, field: 'title', operator: 'contains', value: 'c', position: 1)
    folder
  end

  def call(new_name: nil)
    described_class.call(source: source, current_user: cloner, new_name: new_name)
  end

  it 'succeeds and returns the persisted clone as the resource' do
    result = call
    expect(result).to be_success
    expect(result.resource).to be_persisted
    expect(result.resource.id).not_to eq(source.id)
  end

  it 'deep-copies the full rule tree preserving order and values' do
    clone = call.resource

    groups = clone.smart_folder_rule_groups.order(:position)
    expect(groups.map(&:name)).to eq(%w[G1 G2])
    expect(groups.first.smart_folder_rules.order(:position).map(&:value)).to eq(%w[a b])
    expect(groups.second.smart_folder_rules.order(:position).map(&:value)).to eq(%w[c])
  end

  it 'assigns the acting user as owner and starts fully private' do
    clone = call.resource
    expect(clone.user).to eq(cloner)
    expect(clone.is_public).to be(false)
    # dup carries the source's public_access_level (2); the clone must reset it to 0
    # so a private copy can never inherit a public access level.
    expect(clone.public_access_level).to eq(0)
  end

  it 'copies descriptive columns from the source' do
    clone = call.resource
    expect(clone).to have_attributes(target_object_type: 'Ticket', description: 'Quelle', project_id: project.id)
  end

  it 'does not carry over shares' do
    create(:smart_folder_share, smart_folder: source, user: create(:user))

    clone = call.resource
    expect(clone.smart_folder_shares).to be_empty
  end

  it 'defaults the name to "Kopie von …"' do
    expect(call.resource.name).to eq(I18n.t('smart_folders.copy_of', name: source.name))
  end

  it 'honours an explicit name override' do
    expect(call(new_name: 'Klon X').resource.name).to eq('Klon X')
  end

  it 'is atomic: a failure while copying rules rolls back the whole clone' do
    # Blow up while reading the SECOND source group's rules — after the clone
    # folder and first group are already written inside the transaction. Matched
    # by id so only the source group triggers it (the clone tree has other ids).
    boom_id = source.smart_folder_rule_groups.order(:position).second.id
    allow_any_instance_of(SmartFolderRuleGroup)
      .to receive(:smart_folder_rules).and_wrap_original do |original, *args|
        raise ActiveRecord::RecordInvalid, SmartFolderRule.new if original.receiver.id == boom_id

        original.call(*args)
      end

    expect { call }.not_to change(SmartFolder, :count)
  end
end
