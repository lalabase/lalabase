# frozen_string_literal: true

require 'rails_helper'

# What: the audit answer for the deletion register (AVV § 12 Abs. 7, L3 of
#       doc/loeschverzeichnis_plan.md).
# Type: Request spec, matching the convention of the neighbouring admin specs.
# Why:  This page is what a controller actually receives when it asks for proof.
#       Three of its properties are contract text since L5 and would all be easy
#       to lose in a refactor without any test noticing: the register's start
#       date, entries whose backup confirmation never arrived, and the fact that
#       an entry stays readable after the organisation it concerns is gone.
RSpec.describe 'Admin::DeletionRegisters', type: :request do
  let(:admin_beuser) { create(:beuser) }

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  def record(organisation_id: SecureRandom.uuid, organisation_name: 'Muster GmbH', **attrs)
    AttachmentDeletionRecord.create!(
      organisation_id: organisation_id,
      organisation_name: organisation_name,
      storage_key: SecureRandom.hex(8),
      filename: 'Vertrag.pdf',
      content_type: 'application/pdf',
      byte_size: 1024,
      record_type: 'Document',
      deleted_at: 1.day.ago,
      **attrs
    )
  end

  it 'requires a logged-in operator' do
    get admin_deletion_register_path

    expect(response).to redirect_to(admin_log_in_path)
  end

  describe 'GET /admin/deletion_register' do
    before { log_in_admin }

    it 'lists an entry with its metadata' do
      record(filename: 'Kuendigung.pdf', organisation_name: 'Beispiel AG')

      get admin_deletion_register_path

      expect(response.body).to include('Kuendigung.pdf')
      expect(response.body).to include('Beispiel AG')
    end

    # The contract now states the start date, because everything deleted before
    # it appears nowhere. An answer that omits it implies completeness it does
    # not have.
    it 'names the date the register started' do
      entry = record
      entry.update_column(:created_at, Time.zone.local(2026, 8, 5, 12, 0))

      get admin_deletion_register_path

      expect(response.body).to include(I18n.l(Date.new(2026, 8, 5)))
    end

    it 'says so when the register is still empty' do
      get admin_deletion_register_path

      expect(response.body).to include(I18n.t('admin.deletion_registers.show.register_empty'))
    end

    # Not a detail: a row without confirmation is a row whose backup expiry
    # nobody has proven. Shown twice on purpose, as a count and per row, because
    # the marker alone is invisible from page two onwards.
    it 'marks an entry whose backup confirmation never arrived' do
      record(backup_deleted_at: nil)

      get admin_deletion_register_path

      expect(response.body).to include(I18n.t('admin.deletion_registers.show.pending_confirmation'))
    end

    it 'keeps the confirmed date and the computed expiry apart' do
      record(backup_deleted_at: Time.zone.local(2026, 9, 10), backup_expires_at: Date.new(2026, 9, 24))

      get admin_deletion_register_path

      expect(response.body).to include(I18n.l(Date.new(2026, 9, 10)))
      expect(response.body).to include(
        I18n.t('admin.deletion_registers.show.expires_at', date: I18n.l(Date.new(2026, 9, 24)))
      )
    end

    describe 'the organisation filter' do
      # The whole reason the register carries a denormalised name and no foreign
      # key: proof is asked for AFTER the contract ended, when the organisation
      # row is gone. A filter built from the organisations table would offer
      # nothing here.
      it 'offers an organisation that no longer exists' do
        gone = SecureRandom.uuid
        record(organisation_id: gone, organisation_name: 'Aufgeloest GmbH')

        get admin_deletion_register_path

        expect(::Organisation.exists?(gone)).to be(false)
        expect(response.body).to include('Aufgeloest GmbH')
        expect(response.body).to include(gone)
      end

      it 'restricts the entries to the selected organisation' do
        mine = SecureRandom.uuid
        record(organisation_id: mine, organisation_name: 'Meine GmbH', filename: 'meins.pdf')
        record(organisation_id: SecureRandom.uuid, organisation_name: 'Fremde GmbH', filename: 'fremd.pdf')

        get admin_deletion_register_path(organisation_id: mine)

        expect(response.body).to include('meins.pdf')
        expect(response.body).not_to include('fremd.pdf')
      end

      # The app overrides pagy_url_for and rebuilds the query from a fixed
      # allowlist that does not contain organisation_id, which is why the links
      # are built by hand in the view. Without this test the second page falls
      # back to "all organisations": an answer about one controller's deletions
      # quietly becomes an answer about everybody's, and page one looks correct
      # the whole time. Found by a mutation probe, not by review.
      it 'carries the filter into the next page' do
        stub_const('Admin::DeletionRegistersController::ENTRIES_PER_PAGE', 1)
        mine = SecureRandom.uuid
        2.times { record(organisation_id: mine, organisation_name: 'Meine GmbH') }

        get admin_deletion_register_path(organisation_id: mine)

        # Through Nokogiri, not include(): link_to escapes the ampersand, so a
        # raw string comparison would fail on a correct link.
        hrefs = Nokogiri::HTML(response.body).css('nav a').map { |a| a['href'] }
        expect(hrefs).to include(admin_deletion_register_path(page: 2, organisation_id: mine))
      end

      # organisation_id is a uuid column. An unparsable value would reach
      # PostgreSQL and raise instead of producing an answer, so the parameter is
      # only accepted when it names an organisation present in the register.
      it 'ignores a value that is not a known organisation' do
        record(filename: 'sichtbar.pdf')

        get admin_deletion_register_path(organisation_id: 'kein-uuid')

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('sichtbar.pdf')
      end
    end

    # Entries without an organisation (user export archives, unresolvable
    # carriers) belong to no per-organisation answer. Counting them separately
    # keeps the unfiltered total from looking like the sum of all organisations.
    it 'counts entries without an organisation separately' do
      record(organisation_id: nil, organisation_name: nil)

      get admin_deletion_register_path

      expect(response.body).to include(I18n.t('admin.deletion_registers.show.stat_without_organisation'))
      expect(response.body).to include(I18n.t('admin.deletion_registers.show.organisation_unknown'))
    end
  end
end
