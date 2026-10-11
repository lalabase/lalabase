# frozen_string_literal: true

# == Schema Information
#
# Table name: personal_access_token_organisations
#
#  id                       :uuid             not null, primary key
#  all_projects             :boolean          default(TRUE), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  organisation_id          :uuid             not null
#  personal_access_token_id :uuid             not null
#
# Indexes
#
#  idx_pat_orgs_uniq                                             (personal_access_token_id,organisation_id) UNIQUE
#  index_personal_access_token_organisations_on_organisation_id  (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (personal_access_token_id => personal_access_tokens.id)
#
require 'rails_helper'

RSpec.describe PersonalAccessTokenOrganisation, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:pat) { create(:personal_access_token, user: user, organisations: [organisation]) }

  before { ActsAsTenant.current_tenant = organisation }

  describe 'associations' do
    it { should belong_to(:personal_access_token) }
    it { should belong_to(:organisation) }
  end

  describe 'validations' do
    it 'prevents duplicate (token, organisation) pairs' do
      duplicate = pat.personal_access_token_organisations.build(organisation: organisation)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:organisation_id]).to be_present
    end

    it 'defaults all_projects to true' do
      pat_without_org = create(:personal_access_token, user: user, organisations: [organisation])
      link = pat_without_org.personal_access_token_organisations.first
      expect(link.all_projects).to be true
    end
  end
end
