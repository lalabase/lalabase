# frozen_string_literal: true

namespace :ai_credentials do
  # DEPRECATED — kept only because older ops notes reference it. Covers ONE of
  # the six encrypted columns; the maintained entry point is
  # `encryption:reencrypt_tokens`, which sweeps every registered table
  # (TokenReencryptable) and fails loudly on skipped rows.
  desc 'VERALTET: nur ai_credentials — stattdessen encryption:reencrypt_tokens verwenden'
  task reencrypt_access_tokens: :environment do
    warn 'ai_credentials:reencrypt_access_tokens ist VERALTET und deckt nur ai_credentials ab — ' \
         'bitte encryption:reencrypt_tokens verwenden (alle verschluesselten Spalten, harter Exit bei Skips).'
    result = Admin::AiCredential.reencrypt_access_tokens!
    puts "ai_credentials:reencrypt_access_tokens — #{result[:processed]} Credential(s) neu verschluesselt, " \
         "#{result[:failed]} uebersprungen."
    if result[:failed].positive?
      # Same gate as encryption:reencrypt_tokens: whoever follows an OLD runbook
      # into this task must not get a green exit over unreadable rows.
      abort "ai_credentials:reencrypt_access_tokens — #{result[:failed]} Zeile(n) uebersprungen (Details im Log). " \
            'NICHT mit der Schluessel-Rotation fortfahren, bevor das geklaert ist.'
    end
  end
end
