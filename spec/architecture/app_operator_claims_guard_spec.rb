# frozen_string_literal: true

require 'rails_helper'

# What: the pages a signed-out visitor sees make no claim that belongs to US
#   rather than to whoever runs this instance.
# Why: this application runs on other people's servers. Until 20.09.2026 the
#   sign-in panel told every visitor "Hosted in Germany | DPA included" and put
#   `lalabase.app/inbox` in its window chrome, and the sign-up form offered our
#   founder discount. An instance in Vienna said the opposite of the truth to
#   its own people, and promised a data processing agreement its operator never
#   signed.
#
#   app_legal_identity_guard_spec.rb does not catch these: it looks for
#   StaticHelper::, public legal routes and t('static.'. This copy sits under
#   devise.* and views.devise.*, and the comment in the locale file says the
#   keys were copied out of the pricing page so they would stop being static.*.
#   The claim travelled with them.
module AppOperatorClaimsGuard
  # The I18n scopes a signed-out visitor reads. Everything else in the
  # application is seen by people who already know whose instance they are on.
  SCOPES = [
    %w[devise sessions new],
    %w[devise registrations new],
    %w[devise registrations disabled],
    %w[devise passwords new],
    %w[devise passwords edit],
    %w[devise confirmations new],
    %w[devise unlocks new],
    %w[views devise shared],
    %w[views devise registrations disabled]
  ].freeze

  # A claim only the operator can make, or only we can.
  PATTERNS = {
    'our domain' => /lalabase\.(app|com|de)/i,
    'where it is hosted' => /\b(Deutschland|Germany|Hosting|hosted)\b/i,
    'a contract with us' => /\b(AVV|DPA|Auftragsverarbeitung|data processing agreement)\b/i,
    'a price or a discount' => /\d\s*(%|€|EUR\b)|\b\d+\s*(Prozent|percent)\b/i,
    'billing terms' => /\b(Rechnung|invoice|kündbar|cancel monthly|Abo|subscription)\b/i
  }.freeze

  # There is no allowlist. There was one entry, the founder discount in the
  # sign-up form, and it left the core on 20.09.2026. An empty list invites a
  # first entry; the honest statement now is that the signed-out pages claim
  # nothing that belongs to us.

  def self.strings(locale)
    I18n.backend.send(:init_translations) unless I18n.backend.initialized?
    SCOPES.flat_map do |scope|
      subtree = I18n.backend.send(:translations)[locale]&.dig(*scope.map(&:to_sym))
      flatten(subtree, "#{scope.join('.')}.")
    end
  end

  def self.flatten(node, prefix)
    case node
    when Hash then node.flat_map { |key, value| flatten(value, "#{prefix}#{key}.") }
    when Array then node.each_with_index.map { |value, index| ["#{prefix}#{index}", value.to_s] }
    when nil then []
    else [[prefix.chomp('.'), node.to_s]]
    end
  end

  # Only what a visitor can read: ERB tags are blanked out, comments and code
  # with them. Without this, `<%= index + 1 %>` reads as "1 %" and trips the
  # price pattern, and the comment explaining why the hosting pill left trips
  # the hosting one. Newlines survive so the line numbers stay true.
  def self.literal_text(path)
    File.read(path).gsub(/<%.*?%>/m) { |tag| tag.gsub(/[^\n]/, ' ') }.lines
  end

  def self.findings(locale)
    strings(locale).flat_map do |key, value|
      PATTERNS.filter_map { |name, pattern| "#{locale}.#{key}: #{name} (#{value[0, 60]})" if value.match?(pattern) }
    end
  end
end

RSpec.describe 'Operator claims on the signed-out pages', type: :model do
  I18n.available_locales.each do |locale|
    it "makes no claim of ours in #{locale}" do
      offenders = AppOperatorClaimsGuard.findings(locale)

      expect(offenders).to be_empty,
                           "Copy a signed-out visitor reads, claiming something only we can claim:\n" \
                           "#{offenders.join("\n")}\n\n" \
                           'This application runs on other people\'s servers. Where it is hosted, ' \
                           'what contract exists and what it costs are the operator\'s to say, not ' \
                           'ours. Operator identity comes from LegalIdentity.'
    end
  end

  # The same claim can hide in markup instead of a locale file. lalabase.app/inbox
  # sat in a view, and a claim typed straight into ERB skips the locale files
  # altogether -- measured: with only the domain pattern here, pasting
  # "50 % Rabatt fuer Neugruender" into the sign-up view stayed green.
  it 'keeps our claims out of the signed-out views' do
    files = Dir[Rails.root.join('app/views/devise/**/*.erb')] +
            [Rails.root.join('app/views/layouts/application_auth.html.erb').to_s]
    offenders = files.flat_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      AppOperatorClaimsGuard.literal_text(path).each_with_index.flat_map do |line, index|
        AppOperatorClaimsGuard::PATTERNS
          .filter_map { |name, pattern| "#{relative}:#{index + 1}: #{name}" if line.match?(pattern) }
      end
    end

    expect(offenders).to be_empty,
                         "Our claims, on a page someone else's visitors read:\n#{offenders.join("\n")}\n\n" \
                         'The instance names itself through request.host; everything else is the ' \
                         "operator's to say."
  end
end
