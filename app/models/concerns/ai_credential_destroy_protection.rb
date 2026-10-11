# frozen_string_literal: true

# Shared destroy guard for the two classes mapping to the ai_credentials table:
# AiCredential (runtime) and Admin::AiCredential (the admin BACKEND, which is the
# actual create/edit/delete surface). Registered on the runtime model alone the
# guard was not merely incomplete but a complete NO-OP: the only destroy caller in
# the whole app is Admin::AiCredentialsController#destroy, and it deletes through
# Admin::AiCredential — the class that never carried the callback. So the last
# active credential of a provider, the one runtime traffic is routed to, could be
# removed without a word. Same reasoning as AiCredentialPricing and
# AiCredentialProviderRules: a rule on one of two classes writing the same table
# is toothless on the path where the writes really happen.
#
# Two destroy guards live here (P1 added the first, as announced):
#
#   1. referenced by an AI package — the credential is part of a published
#      offering, so deleting it would break every organisation on that package.
#   2. the provider's default credential — the P0 rule above.
#
# Declaration order is the firing order and it is deliberate: a credential that
# is BOTH a package's embedding slot and its provider's default must report the
# packages, because that is the fact the operator has to act on first (unpin it
# there, or the deletion stays impossible either way).
#
# The FK ai_packages.embedding_credential_id / ai_package_tiers.chat_credential_id
# → ai_credentials is NO ACTION and remains the last instance; this callback is
# the friendly line in front of it, turning a raw InvalidForeignKey into a
# sentence naming the packages.
#
# DISABLING is guarded too, not just deleting. `enabled: false` has the same
# runtime effect as removal — every package validation rejects a disabled
# credential (:disabled) — so protecting only `destroy` left the whole guard
# one click wide: the operator could disable a referenced credential, and the
# package would afterwards be unsaveable from its OWN form, with no way to
# repair the field from there. A guard on an outcome has to cover every path to
# that outcome, not just the one named after it.
module AiCredentialDestroyProtection
  extend ActiveSupport::Concern

  included do
    before_destroy :ensure_not_referenced_by_package
    before_destroy :ensure_not_last_active
    before_update :ensure_not_disabling_referenced_credential
  end

  private

  def ensure_not_disabling_referenced_credential
    return unless will_save_change_to_enabled?(from: true, to: false)

    packages = referencing_packages
    return if packages.empty?

    errors.add(:base, :cannot_disable_referenced_by_package, packages: packages.map(&:name).join(', '))
    throw :abort
  end

  # Both roles count — a package's embedding slot and any of its chat tiers.
  # Named in the message rather than merely counted: "referenced by 2 packages"
  # would send the operator hunting through the package list.
  def ensure_not_referenced_by_package
    packages = referencing_packages
    return if packages.empty?

    errors.add(:base, :cannot_delete_referenced_by_package, packages: packages.map(&:name).join(', '))
    throw :abort
  end

  def referencing_packages
    AiPackage.references_by_credential([id]).fetch(id, []).map { |reference| reference[:package] }.uniq
  end

  # Model-neutral by necessity: Admin::AiCredential has no for_provider scope
  # (only by_provider), so the condition is spelled as a plain where. Semantics
  # are unchanged from the runtime-only version — protected is exactly the row
  # that is active AND the last active one of its provider; inactive or disabled
  # rows stay freely deletable.
  def ensure_not_last_active
    return unless active? && self.class.where(provider: provider, active: true).count == 1

    errors.add(:base, :cannot_delete_last_active, provider: provider)
    throw :abort
  end
end
