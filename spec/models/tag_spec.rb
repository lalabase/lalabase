# frozen_string_literal: true

# == Schema Information
#
# Table name: tags
#
#  id              :uuid             not null, primary key
#  name            :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid
#
# Indexes
#
#  index_tags_on_name_and_organisation_id  (name,organisation_id) UNIQUE
#  index_tags_on_organisation_id           (organisation_id)
#  index_tags_on_user_id                   (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe Tag, type: :model do
  let(:organisation) { create(:organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'validations' do
    it { should validate_presence_of(:name) }

    it 'validates uniqueness of name scoped to organisation_id' do
      ActsAsTenant.with_tenant(organisation) do
        create(:tag, name: 'important', organisation: organisation)
        duplicate_tag = build(:tag, name: 'important', organisation: organisation)
        expect(duplicate_tag).not_to be_valid
        expect(duplicate_tag.errors[:name]).to be_present
      end
    end

    it 'allows same name in different organisations' do
      org1 = create(:organisation)
      org2 = create(:organisation)

      ActsAsTenant.with_tenant(org1) do
        create(:tag, name: 'important', organisation: org1)
      end

      ActsAsTenant.with_tenant(org2) do
        tag2 = build(:tag, name: 'important', organisation: org2)
        expect(tag2).to be_valid
      end
    end
  end

  describe 'associations' do
    it 'belongs to organisation' do
      ActsAsTenant.without_tenant do
        tag = Tag.new(name: 'test', organisation_id: nil)
        expect(tag).not_to be_valid
        expect(tag.errors[:organisation]).to be_present
      end
    end

    it { should have_many(:taggings).dependent(:destroy) }
  end

  describe '#normalize_name' do
    it 'downcases and strips name before saving' do
      ActsAsTenant.with_tenant(organisation) do
        tag = create(:tag, name: ' ImPoRtAnt ')
        expect(tag.name).to eq('important')
      end
    end
  end

  # The one spelling of a name and the rule for a name typed freely (the bulk
  # change, Tickets::Changes::AddRemoveTags). Read against the constants, so a
  # changed limit moves the boundary here too.
  describe '.normalize_name' do
    it 'strips and downcases, and turns nil into an empty name' do
      expect(described_class.normalize_name("  KuNde-X \n")).to eq('kunde-x')
      expect(described_class.normalize_name(nil)).to eq('')
    end
  end

  describe '.acceptable_new_name?' do
    let(:longest) { 'a' * described_class::MAX_NAME_LENGTH }

    it 'accepts a name of exactly the limit and refuses one character more' do
      expect(described_class.acceptable_new_name?(longest)).to be(true)
      expect(described_class.acceptable_new_name?("#{longest}a")).to be(false)
    end

    # Characters, as the panel counts them too (lib/new_tag_name.js).
    it 'counts an emoji as one character' do
      rocket = "\u{1F680}"
      expect(described_class.acceptable_new_name?(('a' * (described_class::MAX_NAME_LENGTH - 1)) + rocket)).to be(true)
      expect(described_class.acceptable_new_name?(longest + rocket)).to be(false)
    end

    it 'measures the name after normalizing, so blanks around it do not count' do
      expect(described_class.acceptable_new_name?("  #{longest}  ")).to be(true)
    end

    it 'refuses the separator anywhere in the name, and a blank name' do
      expect(described_class.acceptable_new_name?("kunde#{described_class::NAME_SEPARATOR}x")).to be(false)
      expect(described_class.acceptable_new_name?(described_class::NAME_SEPARATOR)).to be(false)
      expect(described_class.acceptable_new_name?('   ')).to be(false)
      expect(described_class.acceptable_new_name?(nil)).to be(false)
    end
  end

  describe '.counts_by_type' do
    it 'returns tag counts for a given taggable type' do
      ActsAsTenant.with_tenant(organisation) do
        tag = create(:tag, name: 'important', organisation: organisation)
        project = create(:project, organisation: organisation)

        note1 = create(:note, project: project, organisation: organisation)
        note2 = create(:note, project: project, organisation: organisation)
        ticket = create(:ticket, project: project, organisation: organisation)

        # Create taggings
        create(:tagging, tag: tag, taggable: note1)
        create(:tagging, tag: tag, taggable: note2)
        create(:tagging, tag: tag, taggable: ticket)

        # Get counts by type
        note_counts = Tag.counts_by_type('Note')
        ticket_counts = Tag.counts_by_type('Ticket')

        expect(note_counts[tag.id]).to eq(2)
        expect(ticket_counts[tag.id]).to eq(1)
      end
    end
  end
end
