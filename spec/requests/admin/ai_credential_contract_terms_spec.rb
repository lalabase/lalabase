# frozen_string_literal: true

require 'rails_helper'

# What this protects: the operator's only way to record what a provider promises
# — and that recording is an assurance the operator gives their own customers.
# Three properties have to hold or the surface misleads:
#   1. Nothing may be recorded without being logged in (it ends up on a customer card).
#   2. A document that supports an assessment cannot be deleted — it IS the evidence.
#   3. An assessment can only be ended, never rewritten.
RSpec.describe 'Admin::AiCredential contract terms', type: :request do
  let(:admin_beuser) { create(:beuser) }
  let(:credential) { create(:ai_credential) }
  let(:today) { Date.current }

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  # An upload as the form sends it, so an UploadedFile and NOT a
  # String. The difference is the whole point of the strip in document_params.
  def pdf_upload(filename)
    Rack::Test::UploadedFile.new(StringIO.new('%PDF-1.4'), 'application/pdf',
                                 original_filename: filename)
  end

  # The form that points at THIS document AND submits via PATCH. Both
  # together: the page carries several forms on the same path (delete)
  # and several PATCH forms (end version); each one alone says nothing.
  def patch_form_for(document)
    path = admin_ai_credential_document_path(credential, document)
    Nokogiri::HTML(response.body).css("form[action='#{path}']").find do |form|
      form.css("input[name='_method']").any? { |field| field['value'] == 'patch' }
    end
  end

  def attach_pdf(document, filename)
    document.file.attach(io: StringIO.new('%PDF-1.4'), filename: filename,
                         content_type: 'application/pdf')
  end

  def document_params(**overrides)
    { ai_credential_document: { document_key: 'sst', title: 'Service Specific Terms',
                                valid_from: today.to_s, url: 'https://example.test/sst',
                                locator: 'Abschnitt Generative AI' }.merge(overrides) }
  end

  def contract_params(**overrides)
    { ai_credential_contract: { training_usage: AiCredentialContract::TRAINING_EXCLUDED,
                                retention_policy: AiCredentialContract::RETENTION_UNSPECIFIED,
                                subprocessors_disclosure: AiCredentialContract::SUBPROCESSORS_UNSPECIFIED,
                                starts_on: today.to_s }.merge(overrides) }
  end

  describe 'authorization' do
    it 'refuses an anonymous document upload' do
      expect { post admin_ai_credential_documents_path(credential), params: document_params }
        .not_to change(AiCredentialDocument, :count)
    end

    it 'refuses an anonymous assessment' do
      expect { post admin_ai_credential_contracts_path(credential), params: contract_params }
        .not_to change(AiCredentialContract, :count)
    end

    it 'refuses an anonymous deletion' do
      document = create(:ai_credential_document, ai_credential: credential)

      expect { delete admin_ai_credential_document_path(credential, document) }
        .not_to change(AiCredentialDocument, :count)
    end
  end

  describe 'the credential page' do
    before { log_in_admin }

    it 'renders the contract section' do
      get admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.contract.section_title'))
    end

    # An unassessed credential is an open task, and the page says so rather than
    # staying silent — silence would read as "nothing to do here".
    it 'states that no assessment exists yet' do
      get admin_ai_credential_path(credential)

      # html_escape, because the sentence contains typographic quotation marks and
      # ERB outputs them escaped. A raw comparison would always fail here.
      expect(response.body).to include(
        ERB::Util.html_escape(I18n.t('views.admin.ai_credentials.contract.none_yet'))
      )
    end

    it 'shows the recorded assessment' do
      create(:ai_credential_contract, ai_credential: credential, starts_on: today,
                                      training_usage: AiCredentialContract::TRAINING_EXCLUDED)

      get admin_ai_credential_path(credential)

      expect(response.body).to include(
        I18n.t("views.admin.ai_credentials.contract.training_usages.#{AiCredentialContract::TRAINING_EXCLUDED}")
      )
    end

    # The PATCH route existed before this page did, so "ending an assessment"
    # was reachable by curl only. A route without a door is not a feature.
    it 'offers the end form for the running assessment' do
      contract = create(:ai_credential_contract, ai_credential: credential, starts_on: today)

      get admin_ai_credential_path(credential)

      expect(response.body).to include(admin_ai_credential_contract_path(credential, contract))
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.contract.end_contract'))
    end

    # The history IS the traceability this feature exists for. Without it the
    # versioning lives in the table and nowhere the operator can see.
    it 'lists superseded assessments with their period' do
      create(:ai_credential_contract, ai_credential: credential, starts_on: today - 90.days,
                                      ends_on: today - 1.day,
                                      training_usage: AiCredentialContract::TRAINING_USED)
      create(:ai_credential_contract, ai_credential: credential, starts_on: today,
                                      training_usage: AiCredentialContract::TRAINING_EXCLUDED)

      get admin_ai_credential_path(credential)

      expect(response.body).to include(I18n.t('views.admin.ai_credentials.contract.history_title'))
      expect(response.body).to include(I18n.l(today - 90.days))
      expect(response.body).to include(
        I18n.t("views.admin.ai_credentials.contract.training_usages.#{AiCredentialContract::TRAINING_USED}")
      )
    end

    # An announced version is not yet in force, so it is not the "current" one —
    # the history is the only place it becomes visible at all.
    it 'marks an announced assessment as such' do
      create(:ai_credential_contract, ai_credential: credential, starts_on: today + 30.days)

      get admin_ai_credential_path(credential)

      expect(response.body).to include(I18n.t('views.admin.ai_credentials.contract.announced_badge'))
    end

    it 'shows no history heading when the only assessment is the current one' do
      create(:ai_credential_contract, ai_credential: credential, starts_on: today)

      get admin_ai_credential_path(credential)

      expect(response.body).not_to include(I18n.t('views.admin.ai_credentials.contract.history_title'))
    end

    it 'groups document versions under one paper' do
      create(:ai_credential_document, ai_credential: credential, document_key: 'sst',
                                      valid_from: today - 200.days)
      create(:ai_credential_document, ai_credential: credential, document_key: 'sst',
                                      valid_from: today - 10.days)

      get admin_ai_credential_path(credential)

      expect(response.body).to include(I18n.t('views.admin.ai_credentials.contract.current_badge'))
    end
  end

  describe 'recording a document' do
    before { log_in_admin }

    it 'stores it with the operator email as audit snapshot' do
      expect { post admin_ai_credential_documents_path(credential), params: document_params }
        .to change { credential.documents.count }.by(1)

      expect(credential.documents.last.added_by_email).to eq(admin_beuser.email)
    end

    it 'normalises the document key' do
      post admin_ai_credential_documents_path(credential), params: document_params(document_key: ' SST ')

      expect(credential.documents.last.document_key).to eq('sst')
    end

    it 'refuses a second version of the same paper on the same day' do
      post admin_ai_credential_documents_path(credential), params: document_params

      expect { post admin_ai_credential_documents_path(credential), params: document_params }
        .not_to change(AiCredentialDocument, :count)
    end

    it 'accepts a later version of the same paper' do
      post admin_ai_credential_documents_path(credential), params: document_params

      expect do
        post admin_ai_credential_documents_path(credential),
             params: document_params(valid_from: (today + 90.days).to_s)
      end.to change(AiCredentialDocument, :count).by(1)
    end

    # The mirror direction of the same spec for correcting: the rule sits in the
    # model so that it holds for BOTH write paths. Checking only the path you
    # just built would leave the older one open.
    it 'refuses a javascript: URL' do
      expect do
        post admin_ai_credential_documents_path(credential),
             params: document_params(url: 'javascript:alert(1)')
      end.not_to change(AiCredentialDocument, :count)
    end
  end

  # Without this path a wrong entry is final: delete locks as soon as the
  # paper backs a version, and adding a corrected row would even sort the
  # wrong one BEFORE the right one because of `newest_first`.
  describe 'correcting a document' do
    before { log_in_admin }

    it 'fixes the date printed on the paper' do
      document = create(:ai_credential_document, ai_credential: credential, valid_from: today)

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { valid_from: '2024-10-15' } }

      expect(document.reload.valid_from).to eq(Date.new(2024, 10, 15))
    end

    # A document that backs an assurance must STAY correctable. Otherwise
    # the most important piece of evidence is exactly the one that is untouchably wrong.
    it 'corrects a document that already supports an assessment' do
      document = create(:ai_credential_document, ai_credential: credential)
      create(:ai_credential_contract, ai_credential: credential).documents << document

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { locator: 'Abschnitt 17' } }

      expect(document.reload.locator).to eq('Abschnitt 17')
    end

    # THE trap of this action: an empty file field sends "", and the
    # has_one_attached writer reads "" as REMOVE. Without the strip in
    # document_params every correction to the cited passage would lose the PDF,
    # silently, with nothing failing.
    it 'keeps the attached PDF when the file field is left empty' do
      document = create(:ai_credential_document, ai_credential: credential)
      document.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'terms.pdf',
                           content_type: 'application/pdf')

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { locator: 'Abschnitt 11.2', file: '' } }

      expect(document.reload.file).to be_attached
      expect(document.locator).to eq('Abschnitt 11.2')
    end

    it 'normalises a corrected key like the create path does' do
      document = create(:ai_credential_document, ai_credential: credential, document_key: 'ssts')

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { document_key: '  SST  ' } }

      expect(document.reload.document_key).to eq('sst')
    end

    it 'refuses a correction that collides with another version of the same paper' do
      create(:ai_credential_document, ai_credential: credential, document_key: 'sst',
                                      valid_from: today - 10.days)
      other = create(:ai_credential_document, ai_credential: credential, document_key: 'sst',
                                              valid_from: today)

      patch admin_ai_credential_document_path(credential, other),
            params: { ai_credential_document: { valid_from: (today - 10.days).to_s } }

      expect(other.reload.valid_from).to eq(today)
      expect(flash[:alert]).to be_present
    end

    it 'refuses an anonymous correction' do
      document = create(:ai_credential_document, ai_credential: credential, locator: 'unberührt')
      reset!

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { locator: 'gekapert' } }

      expect(document.reload.locator).to eq('unberührt')
    end

    # The route is nested, and the lookup runs through @credential.documents: a
    # foreign document simply cannot be found through it. `show_exceptions
    # = :rescuable` (test.rb) turns RecordNotFound into a 404, so the RESPONSE
    # is checked here instead of waiting for an exception.
    it 'cannot be reached for a document of a different credential' do
      foreign = create(:ai_credential_document, locator: 'unberührt')

      patch admin_ai_credential_document_path(credential, foreign),
            params: { ai_credential_document: { locator: 'gekapert' } }

      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.locator).to eq('unberührt')
    end

    # The mirror direction of the strip in document_params. "Empty => keep" is
    # checked above; without THIS side it would stay unproven that a real file
    # survives the strip, and a rework of the condition would silently drop uploads
    # without any spec failing. It only holds because UploadedFile has no `empty?`
    # and is therefore not `blank?`; that is written nowhere in the code.
    it 'attaches a newly uploaded PDF' do
      document = create(:ai_credential_document, ai_credential: credential)

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { file: pdf_upload('neu.pdf') } }

      expect(document.reload.file).to be_attached
      expect(document.file.filename.to_s).to eq('neu.pdf')
    end

    it 'replaces a PDF that is already attached' do
      document = create(:ai_credential_document, ai_credential: credential)
      attach_pdf(document, 'alt.pdf')

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { file: pdf_upload('neu.pdf') } }

      expect(document.reload.file.filename.to_s).to eq('neu.pdf')
    end

    # "Leave empty" means keep, so removing needs its own switch.
    # Otherwise an accidentally attached PDF would be final: exactly
    # the dead end this slice is built against, one level deeper.
    it 'detaches the PDF when the remove switch is set' do
      document = create(:ai_credential_document, ai_credential: credential)
      attach_pdf(document, 'falsch.pdf')

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { locator: 'Abschnitt 3' }, remove_file: '1' }

      expect(document.reload.file).not_to be_attached
      expect(document.locator).to eq('Abschnitt 3')
    end

    it 'keeps the PDF when the remove switch is not set' do
      document = create(:ai_credential_document, ai_credential: credential)
      attach_pdf(document, 'richtig.pdf')

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { locator: 'Abschnitt 3' } }

      expect(document.reload.file).to be_attached
    end

    # Order in the controller: validate first, then purge. The other way round,
    # a REJECTED correction would destroy the PDF anyway, and the notice
    # next to it would not mention it.
    it 'keeps the PDF when the correction itself is rejected' do
      document = create(:ai_credential_document, ai_credential: credential)
      attach_pdf(document, 'beleg.pdf')

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { title: '' }, remove_file: '1' }

      expect(document.reload.file).to be_attached
      expect(flash[:alert]).to be_present
    end

    # ActiveStorage reads a string in the file field as a signed blob ID. The
    # strip only catches "", every other string escaped uncaught as a 500.
    it 'reports an unreadable file instead of crashing' do
      document = create(:ai_credential_document, ai_credential: credential)

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { file: 'nicht-signiert' } }

      expect(response).to redirect_to(admin_ai_credential_path(credential))
      expect(flash[:alert]).to eq(I18n.t('flash.admin.ai_credential_documents.file_unreadable'))
    end

    # The uniqueness validation READS, the index WRITES: two simultaneous
    # corrections both get past the check and only collide at
    # commit. Staged here because the race cannot be run reliably.
    it 'reports a lost race on the unique index instead of crashing' do
      document = create(:ai_credential_document, ai_credential: credential)
      allow_any_instance_of(AiCredentialDocument).to receive(:update)
        .and_raise(ActiveRecord::RecordNotUnique, 'idx_credential_documents_unique_version')

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { locator: 'egal' } }

      expect(response).to redirect_to(admin_ai_credential_path(credential))
      expect(flash[:alert]).to eq(I18n.t('flash.admin.ai_credential_documents.version_conflict'))
    end

    # `link_to` renders the href unfiltered, so a javascript: URL becomes
    # a click payload on the admin page, in its own session. Both
    # write paths must reject it, not only the one you are looking at right now.
    it 'refuses a javascript: URL' do
      document = create(:ai_credential_document, ai_credential: credential,
                                                 url: 'https://example.test/sst')

      patch admin_ai_credential_document_path(credential, document),
            params: { ai_credential_document: { url: 'javascript:alert(1)' } }

      expect(document.reload.url).to eq('https://example.test/sst')
      expect(flash[:alert]).to be_present
    end
  end

  describe 'the edit form' do
    before { log_in_admin }

    # Two assertions that seem obvious and both prove NOTHING:
    #   * the URL: the delete button next to it has always pointed at the same
    #     path; that was green before the form even existed;
    #   * `_method=patch` somewhere in the body: the end-version form on
    #     the same page is a PATCH as well.
    # Only the connection holds: THE form on THIS path with THIS verb.
    # Switched to POST, it would run into a RoutingError without any
    # page-wide string test reacting.
    it 'is rendered for every recorded document, and submits as PATCH' do
      document = create(:ai_credential_document, ai_credential: credential)

      get admin_ai_credential_path(credential)

      expect(response.body).to include(I18n.t('views.admin.ai_credentials.contract.edit_document'))
      expect(patch_form_for(document)).to be_present
    end

    it 'offers the remove-PDF switch only where there is a PDF' do
      create(:ai_credential_document, ai_credential: credential)

      get admin_ai_credential_path(credential)

      expect(response.body).not_to include(I18n.t('views.admin.ai_credentials.contract.label_remove_file'))
    end
  end

  describe 'deleting a document' do
    before { log_in_admin }

    it 'deletes an uncited document' do
      document = create(:ai_credential_document, ai_credential: credential)

      expect { delete admin_ai_credential_document_path(credential, document) }
        .to change(AiCredentialDocument, :count).by(-1)
    end

    # The evidence for a statement the operator made to their customers.
    it 'refuses to delete a document that supports an assessment' do
      document = create(:ai_credential_document, ai_credential: credential)
      contract = create(:ai_credential_contract, ai_credential: credential)
      contract.documents << document

      expect { delete admin_ai_credential_document_path(credential, document) }
        .not_to change(AiCredentialDocument, :count)

      expect(flash[:alert]).to be_present
    end
  end

  describe 'recording an assessment' do
    before { log_in_admin }

    it 'stores it and links the chosen documents' do
      document = create(:ai_credential_document, ai_credential: credential)

      post admin_ai_credential_contracts_path(credential),
           params: contract_params.deep_merge(ai_credential_contract: { document_ids: [document.id] })

      expect(credential.contracts.last.documents).to contain_exactly(document)
    end

    # Order matters, as in PublishPriceList: the running version is clipped
    # BEFORE the new one is created, otherwise the overlap rule refuses it.
    it 'closes the running version instead of overlapping it' do
      running = create(:ai_credential_contract, ai_credential: credential,
                                                starts_on: today - 90.days, ends_on: nil)

      post admin_ai_credential_contracts_path(credential),
           params: contract_params(starts_on: (today + 30.days).to_s)

      expect(running.reload.ends_on).to eq(today + 29.days)
      expect(credential.contracts.count).to eq(2)
    end

    # Retroactive assessment would change a statement that already appeared on a
    # customer card.
    it 'refuses a start date in the past' do
      expect do
        post admin_ai_credential_contracts_path(credential),
             params: contract_params(starts_on: (today - 1.day).to_s)
      end.not_to change(AiCredentialContract, :count)

      expect(flash[:alert]).to be_present
    end

    it 'refuses a day count without limited retention' do
      expect do
        post admin_ai_credential_contracts_path(credential),
             params: contract_params(retention_policy: AiCredentialContract::RETENTION_NONE,
                                     retention_days: 30)
      end.not_to change(AiCredentialContract, :count)
    end

    it 'accepts limited retention with a day count' do
      post admin_ai_credential_contracts_path(credential),
           params: contract_params(retention_policy: AiCredentialContract::RETENTION_LIMITED,
                                   retention_days: 30)

      expect(credential.contracts.last.retention_days).to eq(30)
    end

    # A document of ANOTHER provider must not end up as evidence here.
    it 'ignores a document belonging to a different credential' do
      foreign = create(:ai_credential_document)

      post admin_ai_credential_contracts_path(credential),
           params: contract_params.deep_merge(ai_credential_contract: { document_ids: [foreign.id] })

      expect(credential.contracts.last.documents).to be_empty
    end
  end

  describe 'ending an assessment' do
    before { log_in_admin }

    it 'pulls the end date forward' do
      contract = create(:ai_credential_contract, ai_credential: credential,
                                                 starts_on: today - 10.days, ends_on: nil)

      patch admin_ai_credential_contract_path(credential, contract),
            params: { ai_credential_contract: { ends_on: today.to_s } }

      expect(contract.reload.ends_on).to eq(today)
    end

    # The rule the separate table exists for: rewriting a running assessment
    # would silently change what was stated.
    it 'never changes the assessment itself' do
      contract = create(:ai_credential_contract, ai_credential: credential, starts_on: today - 10.days,
                                                 training_usage: AiCredentialContract::TRAINING_EXCLUDED)

      patch admin_ai_credential_contract_path(credential, contract),
            params: { ai_credential_contract: { ends_on: today.to_s,
                                                training_usage: AiCredentialContract::TRAINING_USED } }

      expect(contract.reload.training_usage).to eq(AiCredentialContract::TRAINING_EXCLUDED)
    end

    it 'refuses to extend it' do
      contract = create(:ai_credential_contract, ai_credential: credential,
                                                 starts_on: today - 10.days, ends_on: today + 30.days)

      patch admin_ai_credential_contract_path(credential, contract),
            params: { ai_credential_contract: { ends_on: (today + 90.days).to_s } }

      expect(contract.reload.ends_on).to eq(today + 30.days)
      expect(flash[:alert]).to be_present
    end
  end
end
