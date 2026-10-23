# frozen_string_literal: true

require 'rails_helper'

# The role editor lists every action of Permission::CATEGORIES. A new action
# without an entry here shows "no description" under a humanized category key,
# in both languages, and nothing else fails.
RSpec.describe RolesHelper, type: :helper do
  %i[de en].each do |locale|
    context "in #{locale}" do
      around { |example| I18n.with_locale(locale) { example.run } }

      Permission::CATEGORIES.each do |category, actions|
        it "names the category #{category}" do
          expect(helper.category_name(category.to_s))
            .to eq(I18n.t("views.helpers.roles.categories.#{category}", raise: true))
        end

        actions.each do |action|
          it "describes #{category}.#{action}" do
            expect(helper.get_permission_description(category.to_s, action))
              .not_to eq(I18n.t('views.helpers.roles.descriptions.none_available'))
          end
        end
      end
    end
  end
end
