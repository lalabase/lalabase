# frozen_string_literal: true

# == Schema Information
#
# Table name: code_symbols
#
#  id                    :uuid             not null, primary key
#  end_line              :integer          not null
#  file_path             :string           not null
#  language              :string           not null
#  metadata              :jsonb            not null
#  name                  :string           not null
#  qualified_name        :string           not null
#  signature             :text
#  start_line            :integer          not null
#  symbol_type           :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_repository_id :uuid             not null
#
# Indexes
#
#  idx_code_symbols_repo_path                   (project_repository_id,file_path)
#  idx_code_symbols_repo_qname                  (project_repository_id,qualified_name)
#  index_code_symbols_on_organisation_id        (organisation_id)
#  index_code_symbols_on_project_repository_id  (project_repository_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#
require 'rails_helper'

RSpec.describe CodeSymbol, type: :model do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'validations' do
    subject { build(:code_symbol) }

    it { is_expected.to be_valid }
    it { is_expected.to validate_inclusion_of(:symbol_type).in_array(described_class::SYMBOL_TYPES) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:qualified_name) }
    it { is_expected.to validate_presence_of(:file_path) }
    it { is_expected.to validate_presence_of(:language) }
    it { is_expected.to validate_inclusion_of(:language).in_array(described_class::LANGUAGES) }

    describe 'language whitelist (positive iteration)' do
      described_class::LANGUAGES.each do |lang|
        it "accepts #{lang.inspect}" do
          expect(build(:code_symbol, language: lang)).to be_valid
        end
      end

      it 'rejects an unknown language string (defends against indexer drift)' do
        expect(build(:code_symbol, language: 'haskell')).not_to be_valid
      end
    end

    it 'rejects end_line before start_line (off-by-one boundary)' do
      sym = build(:code_symbol, start_line: 42, end_line: 41)
      expect(sym).not_to be_valid
      expect(sym.errors[:end_line]).to be_present
    end

    it 'accepts end_line exactly equal to start_line (boundary, single-line)' do
      expect(build(:code_symbol, start_line: 42, end_line: 42)).to be_valid
    end
  end

  describe 'associations' do
    it { is_expected.to belong_to(:project_repository) }
  end

  describe 'tenant scoping' do
    it 'is scoped to current tenant' do
      mine = create(:code_symbol)
      ActsAsTenant.with_tenant(create(:organisation)) do
        theirs = create(:code_symbol)
        expect(described_class.all).to contain_exactly(theirs)
      end
      expect(described_class.all).to contain_exactly(mine)
    end
  end

  describe 'scopes' do
    let!(:ruby_sym) { create(:code_symbol, language: 'ruby', file_path: 'app/services/x.rb') }
    let!(:ts_sym)   { create(:code_symbol, language: 'typescript', file_path: 'src/x.ts') }

    it 'filters by language' do
      expect(described_class.for_language('ruby')).to contain_exactly(ruby_sym)
    end

    it 'filters by file path' do
      expect(described_class.in_file('src/x.ts')).to contain_exactly(ts_sym)
    end

    it 'composes scopes' do
      expect(described_class.for_language('ruby').in_file('app/services/x.rb')).to contain_exactly(ruby_sym)
      expect(described_class.for_language('ruby').in_file('src/x.ts')).to be_empty
    end
  end

  describe 'boundary line values' do
    it 'allows single-line symbols where start_line equals end_line' do
      expect(build(:code_symbol, start_line: 42, end_line: 42)).to be_valid
    end

    it 'allows start_line at zero (defensive — some parsers index from 0)' do
      expect(build(:code_symbol, start_line: 0, end_line: 0)).to be_valid
    end
  end

  describe 'symbol_type whitelist' do
    described_class::SYMBOL_TYPES.each do |t|
      it "accepts #{t.inspect}" do
        expect(build(:code_symbol, symbol_type: t)).to be_valid
      end
    end

    # interface/type/enum ARE valid now (TypeScript extractor, M10) — covered by
    # the positive iteration above. These stay invalid: wrong case and constructs
    # we don't model. Guards against indexer drift silently widening the set.
    %w[CLASS Interface trait variable].each do |bad|
      it "rejects #{bad.inspect}" do
        expect(build(:code_symbol, symbol_type: bad)).not_to be_valid
      end
    end
  end

  describe 'cross-repo isolation' do
    it 'permits identical (qualified_name, file_path) in different repositories' do
      repo_a = create(:project_repository, full_name: 'acme/backend')
      repo_b = create(:project_repository, full_name: 'acme/frontend')
      a = create(:code_symbol, project_repository: repo_a,
                               qualified_name: 'App::Foo#call', file_path: 'app/foo.rb')
      b = create(:code_symbol, project_repository: repo_b,
                               qualified_name: 'App::Foo#call', file_path: 'app/foo.rb')
      expect([a, b]).to all(be_persisted)
    end
  end

  describe 'cascade on project_repository destroy' do
    it 'is destroyed when its project_repository is destroyed' do
      sym  = create(:code_symbol)
      repo = sym.project_repository
      expect { repo.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  describe 'duplicates within a repo' do
    it 'allows multiple symbols sharing the same qualified_name (e.g. method redefined or partial class)' do
      project_repository = create(:project_repository)
      first  = create(:code_symbol, project_repository: project_repository,
                                    qualified_name: 'Foo::Bar#call', file_path: 'a.rb', start_line: 1, end_line: 5)
      second = create(:code_symbol, project_repository: project_repository,
                                    qualified_name: 'Foo::Bar#call', file_path: 'b.rb', start_line: 10, end_line: 15)
      expect(described_class.where(project_repository: project_repository)).to contain_exactly(first, second)
    end
  end
end
