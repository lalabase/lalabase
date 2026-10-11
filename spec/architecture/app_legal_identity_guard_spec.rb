# frozen_string_literal: true

require 'rails_helper'

# What: core code does not read the public website: no StaticHelper constant, no public
#   legal route helper, no static.* translation.
# Why: the public pages leave the core (website split, steps W3 to W6). The operator
#   identity lives in the instance admin settings (LegalIdentity, rendered by the legal
#   helpers in ApplicationHelper); every core page that still reads the website breaks, or
#   shows the Lalabase cloud's company data on a self-hosted instance, once they are gone.
#   The first version of this guard matched only StaticHelper::LEGAL_ENTITY in three
#   directories, so a `link_to ..., privacy_path` or a t('static.pricing...') stayed green.
module AppLegalIdentityGuard
  # Nothing is exempt any more. The public website left the core at W6, so there
  # is no longer a set of files allowed to read it -- and no file that still
  # does. Both lists are gone rather than kept empty: an empty allowlist invites
  # a first entry, and the honest statement now is that the core does not know
  # the website exists.
  #
  # The patterns stay. They are cheap, and they are what would catch somebody
  # re-introducing a link to our marketing pages into an application that other
  # people run on their own servers.

  PATTERNS = {
    'StaticHelper constant' => /\bStaticHelper::/,
    'public legal route helper' => /\b(?:impressum|privacy|terms)_(?:path|url)\b/,
    'public page translation' => /\bt\(\s*['"]static\./
  }.freeze

  def self.core_files
    Dir[Rails.root.join('app/**/*.{rb,erb}')]
      .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
  end

  def self.findings(path)
    File.readlines(Rails.root.join(path)).each_with_index.flat_map do |source, index|
      PATTERNS.filter_map { |name, pattern| "#{path}:#{index + 1}: #{name}" if source.match?(pattern) }
    end
  end
end

RSpec.describe 'App legal identity boundary', type: :model do
  it 'keeps core code off the public website' do
    offenders = AppLegalIdentityGuard.core_files.flat_map { |path| AppLegalIdentityGuard.findings(path) }

    expect(offenders).to be_empty,
                         "Core code reads the public website:\n#{offenders.join("\n")}\n\n" \
                         'That website is a separate program on our own domain, and this one runs on ' \
                         "other people's servers. Operator name and legal URLs come from the instance " \
                         'settings: legal_operator_credit, legal_page_link, legal_footer_links. Texts ' \
                         'get their own keys in the core namespace.'
  end
end
