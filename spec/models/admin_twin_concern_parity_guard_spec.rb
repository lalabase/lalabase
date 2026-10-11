# frozen_string_literal: true

require 'rails_helper'

# Guard: an Admin:: shadow model must carry the same app-defined concerns as its
# tenant-side twin -- unless the difference is listed below WITH a reason.
#
# WHY THIS EXISTS. Admin::Organisation, Admin::Membership, Admin::User and
# friends set self.table_name to the same table as their twin, but they are
# separate classes that NEVER share a save cycle. A callback or concern added
# only to the tenant-side class therefore does nothing in the admin backend --
# silently, because the callbacks do fire, just on a class that does not have
# them. And the admin backend is the operator's path: deleting a customer
# account runs Admin::UsersController#destroy ->
# Admin::User#soft_delete_and_anonymize! -> memberships.destroy_all on
# Admin::Membership.
#
# The same mistake has now happened three times:
#   1. 2026-07-05  ensure_account missing on Admin::Organisation -- organisations
#      created through the admin path never got an Account.
#   2. 2026-08-05  T17 did it right: AiUsageRollupFlushable in BOTH classes.
#   3. 2026-08-05  T16 shipped SeatEventRecording on ::Membership only -- the
#      entire admin half wrote no seat events (found in review, PR #470).
#
# Three times by hand, once wrong, is the "missing abstraction" signal from
# CLAUDE.md. Hence a guard on the PROPERTY rather than another comment.
#
# WHAT IT DOES NOT CLAIM. Asymmetry is not automatically a bug: the shadow models
# exist precisely to shed acts_as_tenant, Devise and soft-delete. Those live in
# the allowlist. The list is SHRINK-ONLY, mirroring
# spec/services/service_convention_guard_spec.rb: an entry that stops being a
# difference must be deleted, and every new difference has to be justified here
# before it can land.
#
# And this guard sees INCLUDES only, not what a hand-written method does with
# them: Admin::User#soft_delete_and_anonymize! is a separate implementation of
# ::User's, and a step (or a concern's single call) present on one side only
# stays invisible here. That was the fourth incident (2026-08-24, export archives
# and private analyses survived an admin erasure) and is pinned behaviourally by
# spec/models/user_erasure_path_parity_spec.rb.
module AdminTwinParity
  # Key format: "<table>|<Module>|<class missing it>"
  #
  # Two groups. The first is deliberate and understood. The second is NOT
  # cleared -- it is recorded so the guard can go green today without laundering
  # the finding into silence. Both were surfaced by this guard on its first run.
  DELIBERATE = [
    # Admin::User is a plain cross-tenant reader. It deliberately carries no
    # Devise, no soft-delete scope and no membership/permission logic -- that is
    # the entire reason the shadow model exists (app/models/admin/user.rb).
    'users|SoftDeletable|Admin::User',
    'users|User::Authenticatable|Admin::User',
    'users|User::Authorization|Admin::User',
    'users|User::DeletionLifecycle|Admin::User',
    'users|User::OrganisationMembership|Admin::User',
    'users|User::Presence|Admin::User',
    'users|User::SystemAccount|Admin::User',

    # REQUIRED asymmetry, not an oversight: TokenReencryptable registers per
    # TABLE, and exactly one model may do so (token_reencryptable.rb:11). Its
    # own guard raises "duplicate TokenReencryptable registration for table" on
    # a second include, and the sweep runs find_each over the table, so the twin
    # without the include misses no rows at all. Adding it to both sides would
    # break CI. Which of the two twins holds the registration is cosmetic --
    # Organisation holds it for `organisations`, Admin::AiCredential for
    # `ai_credentials`.
    'organisations|TokenReencryptable|Admin::Organisation',
    'ai_credentials|TokenReencryptable|AiCredential',

    # No operator write path exists: there is no Admin::ProjectsController and
    # no create/update/save on Admin::Project anywhere in app/. The class is
    # only reached through associations (admin/organisation.rb:126,
    # admin/user.rb:100, admin/project_permission.rb:76); the single write is
    # the cascaded dependent: :destroy when an organisation is deleted. Nothing
    # for an audit trail to record. Revisit if an admin project screen appears.
    'projects|Trackable|Admin::Project',
    'projects|ProjectTrackable|Admin::Project',

    # OneLineText is a formatting helper (one private method, no callback, no
    # validation), so no save cycle is missed on either side. Its only caller on
    # this table is Project#one_line_name, the form of the name for the
    # assistant's prompt, and Admin::Project has no such surface: an include
    # there would claim a parity that nothing uses.
    'projects|OneLineText|Admin::Project'
  ].freeze

  # NOT cleared -- an open question, deliberately visible rather than merged
  # into the list above. Same SHAPE as the three incidents in the header: a
  # side-effect concern on one twin and absent on the other, with a real
  # operator write path behind it.
  UNRESOLVED = [
    # Admin::User#soft_delete_and_anonymize! IS an operator
    # write path -- Admin::UsersController#destroy runs it -- and it leaves no
    # Activity record. Either that is a decision (then it belongs above, with
    # the reason) or the admin backend erases users without an audit trail.
    'users|UserTrackable|Admin::User'
  ].freeze

  ALLOWED = (DELIBERATE + UNRESOLVED).freeze

  APP_ROOT = Rails.root.join('app').to_s

  class << self
    # Tables carrying more than one concrete model -- the twin pairs.
    #
    # Anonymous classes (name = nil) are spec scaffolding:
    # spec/config/active_record_encryption_rotation_spec.rb builds
    # `Class.new(ApplicationRecord)` readers on project_repositories that leak
    # into descendants until the GC collects them. Without this filter the guard
    # reports "project_repositories|TokenReencryptable|" -- an offender with an
    # empty class name -- and whether it does depends on spec order and garbage
    # collection. Same filter, same reason as
    # spec/models/token_reencryptable_guard_spec.rb#skip_class?.
    def twin_groups
      Rails.application.eager_load!
      ApplicationRecord.descendants
                       .reject { |klass| klass.abstract_class? || klass.name.nil? }
                       .group_by(&:table_name)
                       .select { |_table, klasses| klasses.size > 1 }
    end

    # Only modules DEFINED IN THIS APP: Rails' own mixins differ between the two
    # classes for reasons that have nothing to do with our side effects.
    def app_concerns(klass)
      klass.included_modules.filter_map do |mod|
        name = mod.name
        next if name.nil?

        source = begin
          Object.const_source_location(name)&.first
        rescue StandardError
          nil
        end
        name if source&.start_with?(APP_ROOT)
      end
    end

    def differences
      twin_groups.flat_map do |table, klasses|
        sets = klasses.to_h { |klass| [klass.name, app_concerns(klass)] }
        sets.values.flatten.uniq.flat_map do |mod|
          sets.reject { |_name, mods| mods.include?(mod) }
              .keys
              .map { |missing| "#{table}|#{mod}|#{missing}" }
        end
      end.sort
    end
  end
end

RSpec.describe 'Admin twin concern parity' do
  let(:differences) { AdminTwinParity.differences }

  it 'kennt ueberhaupt Zwillingspaare (sonst prueft der Guard nichts)' do
    # Without this the whole file could pass vacuously if eager loading or the
    # descendants lookup ever stopped working.
    expect(AdminTwinParity.twin_groups.keys).to include('memberships', 'organisations', 'users', 'roles')
  end

  it 'jedes Modell auf derselben Tabelle traegt dieselben App-Concerns' do
    offenders = differences - AdminTwinParity::ALLOWED

    expect(offenders).to be_empty, <<~MESSAGE
      Ein Concern fehlt auf einem Zwilling derselben Tabelle:

        #{offenders.join("\n  ")}

      Beide Klassen liegen auf derselben Tabelle, teilen aber NIE einen
      Save-Zyklus -- ein Callback nur auf einer Seite feuert im anderen
      Halbraum nie, und zwar lautlos.

      Entweder den Concern in beide Klassen einbinden, oder den Eintrag in
      AdminTwinParity::DELIBERATE aufnehmen und BEGRUENDEN.
    MESSAGE
  end

  it 'die Allowlist enthaelt keine erledigten Eintraege (shrink-only)' do
    stale = AdminTwinParity::ALLOWED - differences

    expect(stale).to be_empty, <<~MESSAGE
      Diese Eintraege sind keine Abweichung mehr und muessen aus der Allowlist
      raus, sonst deckt sie irgendwann etwas, das niemand geprueft hat:

        #{stale.join("\n  ")}
    MESSAGE
  end

  # The two protections live in HELPERS, not in assertions, so a refactor could
  # disarm them without a single example turning red. A total failure would be
  # caught by the shrink-only check (empty differences makes it fail), a partial
  # one would not.
  describe 'die Guard-Mechanik selbst' do
    it 'app_concerns liefert app-eigene Module und laesst Rails-Mixins weg' do
      concerns = AdminTwinParity.app_concerns(Membership)

      expect(concerns).to include('SeatEventRecording')
      expect(concerns).not_to include('ActiveRecord::Core', 'Kernel')
    end

    it 'twin_groups filtert anonyme Spec-Klassen heraus' do
      anonymous = Class.new(ApplicationRecord) { self.table_name = 'memberships' }

      expect(anonymous.name).to be_nil
      expect(AdminTwinParity.twin_groups.fetch('memberships')).not_to include(anonymous)
      expect(AdminTwinParity.differences.grep(/\|\z/)).to be_empty
    end

    it 'differences meldet eine echte Abweichung im erwarteten Schluesselformat' do
      # Proves the detector actually detects: one twin pair is known to differ.
      expect(AdminTwinParity.differences).to include('users|UserTrackable|Admin::User')
    end
  end

  it 'SeatEventRecording steht auf BEIDEN memberships-Klassen (Vorfall 3)' do
    # The concrete regression this guard was built for. Kept as its own example
    # so a future edit to the allowlist cannot quietly re-open it.
    memberships = AdminTwinParity.twin_groups.fetch('memberships')

    expect(memberships.map(&:name)).to contain_exactly('Membership', 'Admin::Membership')
    expect(memberships.reject { |klass| klass.include?(SeatEventRecording) }).to be_empty
  end

  it 'SeatRoleFlipRecording steht auf BEIDEN roles-Klassen (P1)' do
    # The same property one table over, and pinned separately for the same
    # reason: a Role#billable flip moves the seats of every membership of that
    # role, and Admin::Role is a real operator write path the moment a guest-role
    # screen exists. Half a recorder would be silence on the admin side.
    roles = AdminTwinParity.twin_groups.fetch('roles')

    expect(roles.map(&:name)).to contain_exactly('Role', 'Admin::Role')
    expect(roles.reject { |klass| klass.include?(SeatRoleFlipRecording) }).to be_empty
  end
end
