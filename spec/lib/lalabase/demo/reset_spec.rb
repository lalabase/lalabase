# frozen_string_literal: true

require 'rails_helper'

# The nightly reset of the public demo: what visitors wrote goes, the instance's own
# configuration stays, and nothing happens without both latches.
#
# No tenant and no bypass around the examples: the job, the rake task and the setup
# call the reset that way, and a callback that needs a tenant has to fail here too.
RSpec.describe Lalabase::Demo::Reset, :ci_guard do
  let(:fiction) { Lalabase::Demo::Fiction }
  let(:demo_on) { true }

  around do |example|
    flag_was = ENV.fetch(Lalabase::Demo::ENV_FLAG, nil)
    ENV[Lalabase::Demo::ENV_FLAG] = demo_on ? Lalabase::Demo::ENABLED_VALUE : nil
    example.run
  ensure
    ENV[Lalabase::Demo::ENV_FLAG] = flag_was
  end

  # What visitors left behind yesterday, and what the operator configured.
  let!(:visitor_organisation) { create(:organisation, name: 'Written by a visitor') }
  let!(:visitor_persona) { create(:prompt_persona, organisation: visitor_organisation) }
  let!(:visitor_file) { ActiveStorage::Blob.create_and_upload!(io: StringIO.new('a file'), filename: 'visitor.txt') }
  let!(:admin) { create(:beuser) }
  let!(:credential) { create(:ai_credential) }
  let!(:price_list) { create(:price_list) }
  let!(:product_knowledge) { create(:product_knowledge_entry) }
  # A kept record with a file: its attachment and blob sit in wiped tables.
  let!(:contract_terms) do
    create(:ai_credential_document, ai_credential: credential).tap do |document|
      document.file.attach(io: StringIO.new('%PDF-1.4 terms'), filename: 'terms.pdf', content_type: 'application/pdf')
    end
  end

  before { allow(Embeddings::ActivationBackfill).to receive(:call) }

  def mark = SystemSetting.set(Lalabase::Demo::MARKER_KEY, true)

  # The world is written record by record through the actors (see world_spec.rb).
  def reset = Prosopite.pause { described_class.call }

  def stored?(blob) = blob.service.exist?(blob.key)

  describe 'with both latches' do
    before { mark }

    it 'empties what visitors wrote and builds the world again' do
      world = reset

      expect(Organisation.pluck(:id)).to eq([world.organisation.id])
      expect(User.pluck(:email)).to match_array(fiction::PEOPLE.keys.map { fiction.email(_1) })
      expect(PromptPersona.exists?(visitor_persona.id)).to be(false)
      expect(ActiveStorage::Blob.exists?(visitor_file.id)).to be(false)
      expect(stored?(visitor_file)).to be(false)
      expect(Embeddings::ActivationBackfill).to have_received(:call).with(world.organisation)
    end

    it 'gives the world the assistant and the published login' do
      world = reset

      expect(world.organisation).to have_attributes(described_class::ORGANISATION)
      expect(world.signed_in.email).to eq(Lalabase::Demo.login_email)
      expect(world.signed_in.valid_password?(Lalabase::Demo::PASSWORD)).to be(true)
      expect(world.notes).to all(have_attributes(create_embeddings: true))
    end

    it 'keeps the configuration of the instance, the marker among it' do
      reset

      expect(Beuser.exists?(admin.id)).to be(true)
      expect(AiCredential.exists?(credential.id)).to be(true)
      expect(PriceList.exists?(price_list.id)).to be(true)
      expect(ProductKnowledgeEntry.exists?(product_knowledge.id)).to be(true)
      expect(Lalabase::Demo).to be_marked
    end

    it 'keeps the files of what it keeps' do
      blob = contract_terms.file.blob
      reset

      expect(AiCredentialDocument.find(contract_terms.id).file.blob).to eq(blob)
      expect(stored?(blob)).to be(true)
    end

    it 'brings the global personas back' do
      reset

      expect(PromptPersona.where(organisation_id: nil).pluck(:key)).to include(PromptPersona::DEFAULT_KEY)
    end

    # CASCADE would empty a kept table that references a wiped one instead of refusing.
    it 'never cascades' do
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] if payload[:sql].start_with?('TRUNCATE') }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { reset }

      expect(statements.size).to eq(1)
      expect(statements.first).not_to match(/CASCADE/i)
    end

    it 'still starts the embeddings when a file cannot be deleted' do
      allow_any_instance_of(ActiveStorage::Service::DiskService).to receive(:delete).and_raise(Errno::EACCES)

      world = reset
      expect(Embeddings::ActivationBackfill).to have_received(:call).with(world.organisation)
    end

    it 'leaves yesterday in place when the world fails to build' do
      allow_any_instance_of(Lalabase::Demo::World).to receive(:build).and_raise('broken')

      expect { reset }.to raise_error('broken')
      expect(Organisation.exists?(visitor_organisation.id)).to be(true)
      expect(stored?(visitor_file)).to be(true)
    end
  end

  describe 'refuses and touches nothing' do
    def expect_refused
      expect { reset }.to raise_error(described_class::Refused)
      expect(Organisation.exists?(visitor_organisation.id)).to be(true)
      expect(stored?(visitor_file)).to be(true)
    end

    it 'without the marker' do
      expect_refused
    end

    context 'without the flag' do
      let(:demo_on) { false }

      it 'even with the marker' do
        mark
        expect_refused
      end
    end
  end
end
