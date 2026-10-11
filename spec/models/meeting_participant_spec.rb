# frozen_string_literal: true

# == Schema Information
#
# Table name: meeting_participants
#
#  id              :uuid             not null, primary key
#  display_name    :string           not null
#  normalized_name :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  meeting_id      :uuid             not null
#  organisation_id :uuid             not null
#  user_id         :uuid
#
# Indexes
#
#  idx_on_organisation_id_normalized_name_5eadc4a5e5             (organisation_id,normalized_name)
#  index_meeting_participants_on_meeting_id_and_normalized_name  (meeting_id,normalized_name) UNIQUE
#  index_meeting_participants_on_meeting_id_and_user_id          (meeting_id,user_id) UNIQUE WHERE (user_id IS NOT NULL)
#  index_meeting_participants_on_user_id                         (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (meeting_id => meetings.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
require 'rails_helper'

# MeetingParticipant (Slice 1b). Covers: the normalization contract shared with
# the JS parser (same fixture file), the two uniqueness guards that back the DB
# indexes, and the user-deletion snapshot behaviour (name survives, link nulls).
RSpec.describe MeetingParticipant, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project, organisation: organisation) }
  end

  describe '.normalize_name (contract shared with name_normalizer.js)' do
    # Both this spec and spec/javascript/meetings/name_normalizer.test.js load
    # THIS json, so the Ruby and JS implementations cannot drift.
    cases = JSON.parse(
      File.read(Rails.root.join('spec/fixtures/name_normalization_cases.json'))
    )['cases']

    cases.each do |c|
      it "normalizes #{c['input'].inspect} -> #{c['expected'].inspect} (#{c['why']})" do
        expect(described_class.normalize_name(c['input'])).to eq(c['expected'])
      end
    end

    it 'treats nil as empty' do
      expect(described_class.normalize_name(nil)).to eq('')
    end
  end

  describe 'normalization on save' do
    it 'derives normalized_name and trims the display_name' do
      participant = ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, display_name: '  Jürgen   Müller ')
      end

      expect(participant.display_name).to eq('Jürgen Müller')
      expect(participant.normalized_name).to eq('juergen mueller')
    end
  end

  describe 'validations' do
    it 'requires a display_name' do
      participant = ActsAsTenant.with_tenant(organisation) do
        build(:meeting_participant, meeting: meeting, display_name: ' ')
      end
      expect(participant).not_to be_valid
      expect(participant.errors[:display_name]).to be_present
    end

    it 'rejects a duplicate normalized name in the same meeting (Jörg vs Joerg)' do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, display_name: 'Jörg')
        dup = build(:meeting_participant, meeting: meeting, display_name: 'Joerg')

        expect(dup).not_to be_valid
        expect(dup.errors[:normalized_name]).to be_present
      end
    end

    it 'allows the same normalized name in a different meeting' do
      other_meeting = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation)
      end
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, display_name: 'Jörg')
        other = build(:meeting_participant, meeting: other_meeting, display_name: 'Jörg')
        expect(other).to be_valid
      end
    end

    it 'rejects the same user twice in one meeting under different spellings' do
      user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, display_name: 'Karl Krause', user: user)
        dup = build(:meeting_participant, meeting: meeting, display_name: 'Karl', user: user)

        expect(dup).not_to be_valid
        expect(dup.errors[:user_id]).to be_present
      end
    end
  end

  describe 'user deletion (snapshot survives)' do
    it 'nulls user_id but keeps display_name when the linked user is deleted' do
      user = create(:user)
      participant = ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, display_name: 'Karl Krause', user: user)
      end

      # User deletion cascades across tenants; the DB FK (on_delete: :nullify) is
      # what we assert here, so run it without a tenant requirement.
      ActsAsTenant.without_tenant { user.destroy }

      participant.reload
      expect(participant.user_id).to be_nil
      expect(participant.display_name).to eq('Karl Krause')
    end
  end

  describe 'tenant scoping' do
    it 'is scoped to the organisation' do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, display_name: 'Anna Ananas')
      end
      other_org = create(:organisation)

      ActsAsTenant.with_tenant(other_org) do
        expect(MeetingParticipant.count).to eq(0)
      end
      ActsAsTenant.with_tenant(organisation) do
        expect(MeetingParticipant.count).to eq(1)
      end
    end
  end

  # Powers the participant filter dropdown in both the project index and the
  # org-wide index (Slice 1c): distinct people over a set of meetings, deduped by
  # normalized_name (newest spelling wins), shaped for select_tag options.
  describe '.distinct_names_for_meetings' do
    let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:meeting_b) do
      ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project_b, organisation: organisation) }
    end

    it 'returns [display_name, normalized_name] pairs sorted by label, one per normalized name' do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, display_name: 'Zoe Zebra')
        older = create(:meeting_participant, meeting: meeting, display_name: 'Anna Ananas')
        # Same normalized name on another meeting, created later → newest spelling wins.
        create(:meeting_participant, meeting: meeting_b, display_name: 'anna ananas')
        older # reference to keep intent explicit
      end

      result = ActsAsTenant.with_tenant(organisation) do
        MeetingParticipant.distinct_names_for_meetings(Meeting.all)
      end

      expect(result).to eq([['anna ananas', 'anna ananas'], ['Zoe Zebra', 'zoe zebra']])
    end

    it 'only considers participants of the given meeting scope' do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, display_name: 'Inside Ida')
        create(:meeting_participant, meeting: meeting_b, display_name: 'Outside Otto')
      end

      result = ActsAsTenant.with_tenant(organisation) do
        MeetingParticipant.distinct_names_for_meetings(Meeting.where(id: meeting.id))
      end

      expect(result.map(&:first)).to contain_exactly('Inside Ida')
    end
  end
end
