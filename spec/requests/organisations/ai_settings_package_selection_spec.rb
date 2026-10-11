# frozen_string_literal: true

# What: POST /ai_settings/select_package — the write behind the §7 package cards,
#   including the deselect ("Eigene Konfiguration") case and the blocked
#   embedding-effective switch.
# Type: Request spec.
# Why (philosophy): the card grid is only one of TWO doors into this write. A
#   greyed-out button is a courtesy; the server has to refuse the same switch on
#   a hand-crafted POST, or the block is decoration. Both doors are asserted here
#   on purpose — that pairing is the point of the example, not duplication.
#   The switch protocol (who/when, §7) is checked by reloading the record rather
#   than by trusting the response: it is the basis for "EU is the default, US the
#   deliberate deviation", so it has to be written, not merely intended.
# Contract: a curated pick writes package + tier + protocol; a blank id clears it;
#   an embedding-effective switch is refused with the Actor's own wording; a
#   non-admin member gets no write at all.

require 'rails_helper'

RSpec.describe 'Organisations::AiSettings package selection (§7)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  # The org's own (package-less) lane resolves through this one — without it the
  # switch guard has no "before" triple and fails closed on EVERY pick, so the
  # happy path would never be reachable.
  let!(:system_embedding_credential) do
    create(:ai_credential, provider: 'openai', active: true, region: 'eu', company_domicile: 'eu')
  end

  # dims 1536 is the lane the system credential derives, so the default package is
  # a same-lane pick — the only kind P2 allows at all (E5 until P4). Raising `dims`
  # is how an example asks for an embedding-EFFECTIVE switch.
  #
  # `model` does NOT move the lane on this provider, and that is a provider-specific
  # quirk worth knowing before writing a fixture: OpenAiProvider and
  # GoogleVertexProvider answer #default_embedding_model from a CONSTANT, so two
  # openai packages differing only in embedding_model resolve to the SAME triple.
  # OpenAiCompatibleProvider (the rail all three EU presets run on) returns the
  # configured model instead — there the model name alone does move the lane.
  def publish_package(name:, dims: 1536, model: 'text-embedding-3-small')
    credential = create(:ai_credential, region: 'eu', company_domicile: 'eu')
    package = build(:ai_package, name: name, jurisdiction: 'eu_native', active: true,
                                 embedding_credential: credential,
                                 embedding_model: model, embedding_dims: dims)
    AiPackageTier::KEYS.each_with_index do |key, index|
      package.tiers << build(:ai_package_tier, ai_package: package, key: key,
                                               label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                                               chat_credential: credential, position: index)
    end
    package.save!
    package
  end

  describe 'as an org admin' do
    before { sign_in admin }

    it 'records the chosen package together with the switch protocol' do
      package = publish_package(name: 'Europäisch')

      post select_package_organisation_ai_settings_path(organisation),
           params: { ai_package_id: package.id }

      expect(response).to redirect_to(
        organisation_ai_settings_path(organisation, package_mode: 'packages')
      )
      organisation.reload
      expect(organisation.ai_package_id).to eq(package.id)
      # P2 sets the fast rung silently — the switcher itself is P3 (E4).
      expect(organisation.ai_package_tier_key).to eq('fast')
      expect(organisation.ai_package_selected_at).to be_present
      expect(organisation.ai_package_selected_by_id).to eq(admin.id)
    end

    it 'names the package it actually switched to' do
      package = publish_package(name: 'Europäisch')

      post select_package_organisation_ai_settings_path(organisation),
           params: { ai_package_id: package.id }

      expect(flash[:notice]).to eq(
        I18n.t('flash.ai_settings.package_selected', package: 'Europäisch')
      )
    end

    it 'clears the package on a blank id — the same write, not a second path' do
      package = publish_package(name: 'Europäisch')
      organisation.update!(ai_package: package, ai_package_tier_key: 'fast')

      post select_package_organisation_ai_settings_path(organisation), params: { ai_package_id: '' }

      expect(organisation.reload.ai_package_id).to be_nil
      expect(flash[:notice]).to eq(I18n.t('flash.ai_settings.package_cleared'))
    end

    # P4a split the two doors apart for one slice: the Actor already started the
    # migration while the card stayed greyed out, because the consequence dialog
    # that has to precede such a switch did not exist yet. P4b CLOSED that gap —
    # the card is open again, but it opens onto #confirm_package, not onto the
    # write. What the card must never do, in any of the three eras, is post a
    # lane-moving switch from a bare button.
    context 'when the switch would change the vector space' do
      let(:current_package) { publish_package(name: 'Europäisch') }
      let(:other_space_package) { publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large') }

      before do
        organisation.update!(ai_package: current_package, ai_package_tier_key: 'fast')
      end

      it 'routes that card through the consequence dialog instead of posting' do
        # Stated as a precondition so a changed rule fails HERE, loudly, instead
        # of quietly turning the assertions below into a test of nothing.
        expect(other_space_package.embedding_switch_for?(organisation.reload)).to be(true)

        get organisation_ai_settings_path(organisation)

        expect(response.body).to include(
          I18n.t('views.organisations.ai_settings.packages.card.switch_notice')
        )
        expect(response.body).to include(
          confirm_package_organisation_ai_settings_path(organisation, ai_package_id: other_space_package.id)
        )
        # The id travels as a query parameter of the dialog link, never as the
        # hidden field of a form — this is what tells "detour" from "one click
        # away from a metered reindex".
        expect(response.body).not_to include(%(value="#{other_space_package.id}"))
      end

      # The seam has been open since P4a; P4b put a dialog in FRONT of the card,
      # not a second refusal behind it. Asserted rather than assumed.
      it 'accepts the same switch on a direct POST and starts the migration' do
        post select_package_organisation_ai_settings_path(organisation),
             params: { ai_package_id: other_space_package.id }

        expect(organisation.reload.ai_package_id).to eq(other_space_package.id)
        expect(flash[:alert]).to be_blank
        # The space row is what separates "the column changed" from "the search
        # migration actually began" — without it the org would route into a vector
        # space nobody is building. EmbeddingSpace is tenant-scoped and the request
        # has ended, so the read needs its tenant back.
        space = ActsAsTenant.with_tenant(organisation) { EmbeddingSpace.last }
        expect(space.embedding_dims).to eq(3072)
        # NOT 'text-embedding-3-large', although that is what the package declares:
        # OpenAiProvider answers #default_embedding_model from a CONSTANT and
        # ignores the configured name (factory.rb, "KNOWN LIMIT"), so the space is
        # built from the DERIVED triple. Pinned rather than asserted away — this is
        # the same asymmetry that makes an openai package's model rename a no-op
        # while an openai_compatible one moves the lane, and whoever makes the
        # provider honour its configured model has to expect this line to flip.
        expect(space.embedding_model).to eq('text-embedding-3-small')
      end
    end

    # The "Eigene Konfiguration" card is the way BACK, and it moves the lane in
    # exactly the cases the way in does — so it takes the same P4b detour: the
    # dialog first, the write second.
    context 'when DESELECTING would change the vector space' do
      let(:other_space_package) { publish_package(name: 'Groß', dims: 3072, model: 'text-embedding-3-large') }

      before do
        # Placed directly rather than selected through the seam: the card door is
        # what an org would meet, and this sets up the state behind it.
        organisation.update!(ai_package: other_space_package, ai_package_tier_key: 'fast')
      end

      # package_mode=custom opens the pane the way back lives in (D6). An org on a
      # package opens on the package way by default, so without the param this example
      # would fail for the wrong reason.
      it 'sends the custom pane to the dialog instead of straight into the write' do
        get organisation_ai_settings_path(organisation, package_mode: 'custom')

        expect(response.body).to include(
          I18n.t('views.organisations.ai_settings.packages.custom.switch_notice')
        )
        # No ai_package_id on the link: blank means "Eigene Konfiguration" for the
        # dialog exactly as it does for the write (E1-C), so the way back needs no
        # parameter of its own.
        expect(response.body).to include(
          confirm_package_organisation_ai_settings_path(organisation)
        )
        expect(response.body).not_to include(
          I18n.t('views.organisations.ai_settings.packages.custom.select_button')
        )
      end

      it 'accepts the deselection on a direct POST and migrates the way back' do
        post select_package_organisation_ai_settings_path(organisation), params: { ai_package_id: '' }

        expect(organisation.reload.ai_package_id).to be_nil
        expect(flash[:alert]).to be_blank
        # Back onto the org's OWN configuration — the space built here is the
        # custom lane, not the package's, which is what makes this the way back
        # rather than another hop between packages.
        space = ActsAsTenant.with_tenant(organisation) { EmbeddingSpace.last }
        expect(space.embedding_dims).to eq(1536)
      end
    end

    # The counterweight: a same-lane package must still be leaveable, or the guard
    # would be a one-way door rather than a rule about the vector space.
    it 'still offers the way back when the custom lane matches' do
      organisation.update!(ai_package: publish_package(name: 'Europäisch'), ai_package_tier_key: 'fast')

      get organisation_ai_settings_path(organisation, package_mode: 'custom')

      expect(response.body).to include(
        I18n.t('views.organisations.ai_settings.packages.custom.select_button')
      )
    end

    # ⚠️ The pane travels back with the answer, and it is read off the WRITTEN record,
    # not off the request. Without it #show re-derives the mode from state, and the one
    # write that lands in Z3 — "Eigene Konfiguration nutzen" with no credentials stored —
    # re-derives to the package catalogue. The customer would click the custom button,
    # read a success flash and land on the other way, which is the same class of lie D7
    # was built to end.
    describe 'the pane the redirect answers with' do
      it 'opens the custom pane after leaving a package, even with nothing stored yet' do
        organisation.update!(ai_package: publish_package(name: 'Europäisch'), ai_package_tier_key: 'fast',
                             ai_access_token: nil)

        post select_package_organisation_ai_settings_path(organisation), params: { ai_package_id: '' }

        expect(organisation.reload.ai_package_id).to be_nil
        expect(organisation.ai_custom_access_configured?).to be(false)
        expect(response).to redirect_to(
          organisation_ai_settings_path(organisation, package_mode: 'custom')
        )
      end

      # Nothing was written, so the customer should still be looking at what they were
      # looking at: a refusal must not answer with a second surprise.
      it 'keeps the requested pane when the write is refused' do
        post select_package_organisation_ai_settings_path(organisation),
             params: { ai_package_id: SecureRandom.uuid, package_mode: 'custom' }

        expect(flash[:alert]).to be_present
        expect(response).to redirect_to(
          organisation_ai_settings_path(organisation, package_mode: 'custom')
        )
      end

      # Fail closed here too: a crafted value must not travel back out of the controller.
      it 'drops an unknown pane rather than handing it back' do
        post select_package_organisation_ai_settings_path(organisation),
             params: { ai_package_id: SecureRandom.uuid, package_mode: 'both-please' }

        expect(response).to redirect_to(organisation_ai_settings_path(organisation))
      end
    end

    # The rung travels on the same seam as the package: a mismatch between the
    # controller's key and the Actor's would not fail, it would silently drop the
    # value and leave every customer on 'fast'.
    it 'forwards the rung the P3 switcher sends' do
      package = publish_package(name: 'Europäisch')

      post select_package_organisation_ai_settings_path(organisation),
           params: { ai_package_id: package.id, ai_package_tier_key: 'thorough' }

      expect(organisation.reload.ai_package_tier_key).to eq('thorough')
    end

    # KI-Pakete P3: ONE action serves both axes, so the ANSWER has to tell them
    # apart. A customer who moved a cost slider must not be told their package —
    # i.e. the jurisdiction their data is processed in — is now a different one
    # (§2: two axes, and only one of them carries legal weight).
    describe 'a pure rung change' do
      let(:package) { publish_package(name: 'Europäisch') }

      before { organisation.update!(ai_package: package, ai_package_tier_key: 'fast') }

      it 'switches the rung and leaves the package alone' do
        post select_package_organisation_ai_settings_path(organisation),
             params: { ai_package_id: package.id, ai_package_tier_key: 'thorough' }

        organisation.reload
        expect(organisation.ai_package_tier_key).to eq('thorough')
        expect(organisation.ai_package_id).to eq(package.id)
      end

      it 'answers with the rung wording, not the package one' do
        post select_package_organisation_ai_settings_path(organisation),
             params: { ai_package_id: package.id, ai_package_tier_key: 'thorough' }

        expect(flash[:notice]).to eq(
          I18n.t('flash.ai_settings.package_tier_selected',
                 tier: AiPackageTier::DEFAULT_LABELS.fetch('thorough'))
        )
        expect(flash[:notice]).not_to include('Europäisch')
      end

      # The other side of the same distinction: an actual package change keeps
      # the package wording. Without this the rung copy could simply have
      # replaced the package copy and both examples would still pass.
      it 'keeps the package wording for a real package change' do
        successor = publish_package(name: 'Zweitpaket')

        post select_package_organisation_ai_settings_path(organisation),
             params: { ai_package_id: successor.id, ai_package_tier_key: 'thorough' }

        expect(flash[:notice]).to eq(
          I18n.t('flash.ai_settings.package_selected', package: 'Zweitpaket')
        )
      end

      # The race the Actor's row lock exists for, seen from the FLASH rather than
      # from the data. Admin B moves the org to a second package, admin A's stale
      # tab posts the first one back. The Actor behaves correctly — #lock! reloads,
      # the embedding guard runs, both packages share a lane, so the write goes
      # through and the org lands back on 'Europäisch'. The question this example
      # asks is what the customer is TOLD about it.
      #
      # Reading the package id before the Actor ran made the controller compare a
      # value from before the lock against the value after it: stale P against
      # written P, "no package change", and the flash announced "Rechtsraum und
      # Suchindex bleiben unverändert" for a write that had just moved the
      # jurisdiction from the second package back to the first. The one confusion
      # §2's two axes exist to prevent, arriving through the door P3 opened.
      #
      # The competing write goes through update_all ON PURPOSE: it commits the
      # new package id without touching the controller's in-memory @organisation,
      # which is exactly the window between #set_organisation and the Actor's lock.
      it 'reports the package wording when a concurrent write moved the package underneath' do
        competitor = publish_package(name: 'Zweitpaket')
        allow(Actors::SelectAiPackage).to receive(:call).and_wrap_original do |original, **kwargs|
          Organisation.where(id: organisation.id).update_all(ai_package_id: competitor.id)
          original.call(**kwargs)
        end

        post select_package_organisation_ai_settings_path(organisation),
             params: { ai_package_id: package.id, ai_package_tier_key: 'thorough' }

        # The write itself is the Actor's business and unchanged by this fix —
        # asserted so a green flash can never rest on a write that did not happen.
        expect(organisation.reload.ai_package_id).to eq(package.id)
        expect(flash[:notice]).to eq(
          I18n.t('flash.ai_settings.package_selected', package: 'Europäisch')
        )
      end

      # The protocol columns are the audit trail for a cost decision too (§7):
      # who put this org on the expensive rung is the same kind of fact as who
      # chose the jurisdiction.
      it 'stamps the protocol' do
        organisation.update_columns(ai_package_selected_at: nil, ai_package_selected_by_id: nil)

        post select_package_organisation_ai_settings_path(organisation),
             params: { ai_package_id: package.id, ai_package_tier_key: 'thorough' }

        organisation.reload
        expect(organisation.ai_package_selected_by_id).to eq(admin.id)
        expect(organisation.ai_package_selected_at).to be_present
      end
    end

    # A rung outside the ladder is refused by NAME, so the customer hears about
    # the rung rather than about a reindex they never asked for — the Actor's
    # "input first, consequence second" order, seen from the outside.
    it 'refuses an unknown rung without touching the organisation' do
      package = publish_package(name: 'Europäisch')

      post select_package_organisation_ai_settings_path(organisation),
           params: { ai_package_id: package.id, ai_package_tier_key: 'premium' }

      expect(organisation.reload.ai_package_id).to be_nil
      expect(flash[:alert]).to include('premium')
    end

    it 'refuses an unknown package id without touching the organisation' do
      package = publish_package(name: 'Europäisch')
      organisation.update!(ai_package: package, ai_package_tier_key: 'fast')

      post select_package_organisation_ai_settings_path(organisation),
           params: { ai_package_id: SecureRandom.uuid }

      expect(organisation.reload.ai_package_id).to eq(package.id)
      expect(flash[:alert]).to be_present
    end
  end

  describe 'as a plain member' do
    let(:member) { create(:user) }
    let(:member_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }

    let!(:member_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      end
    end

    before { sign_in member }

    # Choosing a package moves where the organisation's data is processed — the
    # same right #update carries, and deliberately the same policy method. A
    # member must be turned away BEFORE the Actor runs, so the refusal is not a
    # failed write but no write at all: no protocol stamp either, which is what
    # tells "denied" apart from "attempted and rejected" in an audit.
    it 'cannot switch the package' do
      package = publish_package(name: 'Europäisch')

      post select_package_organisation_ai_settings_path(organisation),
           params: { ai_package_id: package.id }

      expect(organisation.reload.ai_package_id).to be_nil
      expect(organisation.ai_package_selected_at).to be_nil
      expect(organisation.ai_package_selected_by_id).to be_nil
      expect(response).not_to have_http_status(:ok)
      expect(flash[:notice]).to be_blank
    end
  end

  describe 'as a non-member' do
    let(:outsider) { create(:user) }

    before { sign_in outsider }

    # The membership-scoped lookup in #set_organisation is what keeps a foreign
    # org from being addressed at all — 404, not 403.
    it 'cannot address the organisation' do
      package = publish_package(name: 'Europäisch')

      post select_package_organisation_ai_settings_path(organisation),
           params: { ai_package_id: package.id }

      expect(organisation.reload.ai_package_id).to be_nil
    end
  end
end
