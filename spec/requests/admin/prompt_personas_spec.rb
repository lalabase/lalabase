# frozen_string_literal: true

require 'rails_helper'

# Request spec (real Beuser session + routes), mirroring admin/organisations_spec.
# Exercises the operator-gated global persona pool end to end.
RSpec.describe 'Admin::PromptPersonas', type: :request do
  let(:admin_beuser) { create(:beuser) } # factory: role 'admin', active

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  describe 'authentication (operator-gated, not merely authenticated)' do
    it 'redirects an anonymous visitor to the admin login' do
      get admin_prompt_personas_path
      expect(response).to redirect_to(admin_log_in_path)
    end

    it 'rejects a NON-admin beuser (login refused → no session)' do
      non_admin = create(:beuser, role: 'user')
      post admin_log_in_path, params: { email: non_admin.email, password: non_admin.password }
      get admin_prompt_personas_path
      expect(response).to redirect_to(admin_log_in_path)
    end
  end

  describe 'GET /admin/prompt_personas' do
    it 'lists ONLY the global pool, not per-org personas' do
      create(:prompt_persona, organisation: nil, key: 'overview', system: true)
      create(:prompt_persona, organisation: create(:organisation), key: 'org_only')
      log_in_admin

      get admin_prompt_personas_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('overview')
      expect(response.body).not_to include('org_only') # per-org rows are off this screen
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'POST /admin/prompt_personas' do
    let(:valid_params) do
      { prompt_persona: { key: 'planning', position: 3, active: '1',
                          labels: { de: 'Planung', en: 'Planning' },
                          prompt_fragments: { de: 'DE-Intent', en: 'EN-Intent' } } }
    end

    it 'creates a GLOBAL, non-system persona' do
      log_in_admin

      expect { post admin_prompt_personas_path, params: valid_params }
        .to change(PromptPersona, :count).by(1)

      persona = PromptPersona.find_by(key: 'planning')
      expect(persona.organisation_id).to be_nil
      expect(persona.system?).to be(false)
      expect(response).to redirect_to(admin_prompt_personas_path)
    end

    it 'persists BOTH supported languages and filters unsupported keys (closed permit list)' do
      log_in_admin

      post admin_prompt_personas_path, params: { prompt_persona: {
        key: 'multilang',
        labels: { de: 'DE-Label', en: 'EN-Label', fr: 'FR-leak' },
        prompt_fragments: { de: 'DE-Frag', en: 'EN-Frag', fr: 'FR-leak' }
      } }

      persona = PromptPersona.find_by(key: 'multilang')
      # G2 (whitelist shrink): literal-lock the surviving key set, so dropping a
      # language from Lalabase::Languages::SUPPORTED turns this red instead of
      # silently swallowing EN. G3 (open-hash): 'fr' must NOT survive the permit.
      expect(persona.labels.keys).to match_array(%w[de en])
      expect(persona.prompt_fragments.keys).to match_array(%w[de en])
      expect(persona.labels).not_to have_key('fr')
    end

    it 'FORCES organisation_id nil + system false even when the params try to inject them' do
      org = create(:organisation)
      log_in_admin

      post admin_prompt_personas_path, params: {
        prompt_persona: { key: 'sneaky', labels: { de: 'x' }, prompt_fragments: { de: 'y' },
                          organisation_id: org.id, system: '1' }
      }

      persona = PromptPersona.find_by(key: 'sneaky')
      expect(persona).to be_present
      expect(persona.organisation_id).to be_nil # injected org ignored
      expect(persona.system?).to be(false)      # injected system flag ignored
    end

    # Same shape as the org spec: the neutral row (PromptPersona::NEUTRAL_KEY) is
    # the one persona a form may submit with both fragment textareas empty, which
    # arrives as {"de"=>"", "en"=>""}. Proven through strong params here because
    # this is the form the production row will be created with.
    it 'creates a neutral persona whose fragment fields were left blank in the form' do
      log_in_admin

      expect do
        post admin_prompt_personas_path, params: { prompt_persona: {
          key: PromptPersona::NEUTRAL_KEY, position: 99, active: '1',
          labels: { de: 'Neutral', en: 'Neutral' }, prompt_fragments: { de: '', en: '' }
        } }
      end.to change(PromptPersona, :count).by(1)

      expect(response).to redirect_to(admin_prompt_personas_path)
      persona = PromptPersona.find_by!(organisation_id: nil, key: PromptPersona::NEUTRAL_KEY)
      expect(persona.prompt_fragment('en')).to be_nil
    end

    it 're-renders with 422 on invalid input' do
      log_in_admin
      post admin_prompt_personas_path, params: { prompt_persona: { key: '', labels: {}, prompt_fragments: {} } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'GET new / edit (forms render with all keys present)' do
    it 'renders the new form without missing translations' do
      log_in_admin
      get new_admin_prompt_persona_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('translation missing')
    end

    it 'renders the edit form for a system persona (locked key) without missing translations' do
      persona = create(:prompt_persona, :overview, organisation: nil)
      log_in_admin
      get edit_admin_prompt_persona_path(persona)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'PATCH /admin/prompt_personas/:id' do
    it 'updates label + position of a custom persona' do
      persona = create(:prompt_persona, organisation: nil, key: 'planning', position: 1)
      log_in_admin

      patch admin_prompt_persona_path(persona), params: {
        prompt_persona: { position: 9, labels: { de: 'Neu', en: 'New' }, prompt_fragments: { de: 'a', en: 'b' } }
      }

      expect(persona.reload.position).to eq(9)
      expect(persona.label('de')).to eq('Neu')
    end

    it 'IGNORES a key change on a SYSTEM persona (key is a locked contract)' do
      persona = create(:prompt_persona, :overview, organisation: nil) # system: true, key 'overview'
      log_in_admin

      patch admin_prompt_persona_path(persona), params: {
        prompt_persona: { key: 'hijacked', labels: { de: 'X' }, prompt_fragments: { de: 'Y' } }
      }

      expect(persona.reload.key).to eq('overview') # untouched
    end

    it 'still updates position + active of a NON-overview SYSTEM persona (except drops only :key)' do
      persona = create(:prompt_persona, organisation: nil, key: 'feature_planning', system: true, position: 1)
      log_in_admin

      patch admin_prompt_persona_path(persona), params: {
        prompt_persona: { position: 8, active: '0', labels: { de: 'X' }, prompt_fragments: { de: 'Y' } }
      }

      # except(:key) must strip ONLY the key — position and active stay editable,
      # else operators silently lose control of seeded non-default personas.
      expect(persona.reload.position).to eq(8)
      expect(persona.active?).to be(false)
    end

    it 'refuses to deactivate the global system overview (model invariant → 422)' do
      persona = create(:prompt_persona, :overview, organisation: nil)
      log_in_admin

      patch admin_prompt_persona_path(persona), params: { prompt_persona: { active: '0' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(persona.reload.active?).to be(true)
    end
  end

  describe 'DELETE /admin/prompt_personas/:id' do
    it 'destroys a non-system persona' do
      persona = create(:prompt_persona, organisation: nil, key: 'planning')
      log_in_admin
      expect { delete admin_prompt_persona_path(persona) }.to change(PromptPersona, :count).by(-1)
    end

    it 'blocks destroying a system persona, keeps the row, and shows a friendly alert (no 500)' do
      persona = create(:prompt_persona, :overview, organisation: nil) # system: true
      log_in_admin

      expect { delete admin_prompt_persona_path(persona) }.not_to change(PromptPersona, :count)
      expect(response).to redirect_to(admin_prompt_personas_path)
      expect(flash[:alert]).to be_present
    end
  end
end
