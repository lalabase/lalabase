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
FactoryBot.define do
  factory :code_symbol do
    project_repository
    organisation { project_repository.organisation }
    symbol_type { 'method' }
    sequence(:name) { |n| "method_#{n}" }
    sequence(:qualified_name) { |n| "Foo::Bar##{n}" }
    file_path { 'app/services/foo_bar.rb' }
    start_line { 10 }
    end_line { 25 }
    signature { 'def call(arg)' }
    language { 'ruby' }
    metadata { {} }
  end
end
