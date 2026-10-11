# frozen_string_literal: true

module UserDataExports
  # Assembles the complete file map for a personal data export
  # (Art. 15/20, doc/user_data_export_plan.md):
  #
  #   README.txt                          Art.-15 meta information (per locale)
  #   account.json / preferences.json /   global sources (Registry) — models
  #   memberships.json / …                without tenant scope
  #   organisations/<folder>/…            tenant sources, one with_tenant block
  #                                       per membership org, owner-scoped
  #
  # Org discovery is deliberately MEMBERSHIP-based (all rows, incl. inactive) —
  # D9 role model: content in orgs the user was removed from belongs to the org
  # as data controller and is served via the org export, never via a
  # without_tenant sweep here. Do not "fix" this by lifting the tenant scope.
  class Builder
    def initialize(user)
      @user = user
    end

    # => { "path/inside/zip" => String }
    def files
      result = { 'README.txt' => readme_text }
      Registry.global_sources.each do |source|
        result[source.zip_filename] = as_pretty_json(source.serializer.call(source, user))
      end
      result['preferences.json'] = as_pretty_json(user.preferences || {})
      result.merge!(avatar_file)
      result.merge!(organisation_files)
      result
    end

    private

    attr_reader :user

    # The profile picture is the one blob this export ships (Art. 20: the user
    # uploaded it, it IS their data — unlike org content, which stays an
    # inventory per Option A). Alongside README.txt and preferences.json it is
    # deliberately outside the Registry: the registry audits exported KEYS,
    # and a binary has none. A missing file on disk must not sink the whole
    # export — the picture is still visible and re-downloadable in the profile.
    def avatar_file
      return {} unless user.avatar.attached?

      { "avatar#{user.avatar.filename.extension_with_delimiter}" => user.avatar.download }
    rescue ActiveStorage::FileNotFoundError
      {}
    end

    def organisation_files
      organisations.each_with_object({}) do |organisation, result|
        result.merge!(export_org_slice(organisation))
      end
    end

    # One tenant-scoped bundle of reads per org (bounded by the user's org
    # count) — the repeated identical SQL across orgs is the intentional
    # per-tenant loop, allow-listed in spec/support/prosopite.rb like
    # Dashboard::CrossOrgActionSummary#aggregate_org_slice.
    def export_org_slice(organisation)
      folder = "organisations/#{org_folder_name(organisation)}"
      ActsAsTenant.with_tenant(organisation) do
        Registry.tenant_sources.each_with_object({}) do |source, files|
          # Empty sources still write "[]" — deterministic structure, no
          # "is the file missing or was there no data?" guesswork.
          files["#{folder}/#{source.zip_filename}"] =
            as_pretty_json(source.serializer.call(source, user))
        end
      end
    end

    # ALL memberships, including inactive ones — Art. 15 covers everything
    # still processed, not just what is currently visible.
    def organisations
      user.memberships.includes(:organisation).map(&:organisation).uniq
    end

    # organisations has no slug column; parameterize can end up empty for
    # special-char/CJK names and two orgs may share a name — the short id
    # suffix keeps folders unique and non-empty.
    def org_folder_name(organisation)
      base = organisation.name.to_s.parameterize.presence || 'org'
      "#{base}-#{organisation.id.to_s.first(8)}"
    end

    # Explicit per-locale templates (readme_de/_en) instead of the resolver's
    # locale-variant magic: the variant lookup proved unreliable under
    # ApplicationController.render (picked the .de template with :en active).
    def readme_text
      locale = readme_locale
      I18n.with_locale(locale) do
        ApplicationController.render(
          template: "user_data_exports/readme_#{locale}",
          formats: [:text],
          layout: false,
          locals: { user: user, generated_at: Time.current, privacy_link: LegalIdentity.current.privacy_page_url }
        )
      end
    end

    # The README exists in exactly two languages (readme_de / readme_en), so
    # the choice is binary here regardless of what the preference holds.
    def readme_locale
      user.language_preference.to_s == 'de' ? :de : :en
    end

    def as_pretty_json(payload)
      JSON.pretty_generate(payload.as_json)
    end
  end
end
