# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::ActionTextFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # Creates a filter with a persisted rule.
  # skip_validation: true for operators that are not allowed in the field_config
  def build_filter(operator:, value:, field: 'content', skip_validation: false)
    smart_folder = create(:smart_folder, organisation: organisation, user: user, project: project, target_object_type: 'Ticket')
    rule_group = create(:smart_folder_rule_group, smart_folder: smart_folder)
    rule = build(:smart_folder_rule, smart_folder_rule_group: rule_group, field: field, operator: operator, value: value)

    if skip_validation
      rule.save!(validate: false)
    else
      rule.save!
    end

    described_class.new(rule)
  end

  # ──────────────────────────────────────────────────────────────
  # Path 1: plain_text_version (Note model)
  # ──────────────────────────────────────────────────────────────
  describe 'plain_text_version path (Note)' do
    let!(:note_match) do
      note = build(:note, project: project, organisation: organisation, title: 'Match', creator: user)
      note.content = 'This contains Important Information about the project'
      note.save!
      note
    end

    let!(:note_no_match) do
      note = build(:note, project: project, organisation: organisation, title: 'NoMatch', creator: user)
      note.content = 'Something completely different'
      note.save!
      note
    end

    let!(:note_nil_content) do
      note = build(:note, project: project, organisation: organisation, title: 'NilContent', creator: user)
      note.content = 'placeholder'
      note.save!
      note.update_column(:plain_text_version, nil)
      note
    end

    describe 'contains' do
      it 'findet Datensätze mit passendem Text' do
        filter = build_filter(operator: 'contains', value: 'Important Information')
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_match)
        expect(result).not_to include(note_no_match)
      end

      it 'ist case-insensitive (ILIKE)' do
        filter = build_filter(operator: 'contains', value: 'important information')
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_match)
      end

      it 'schließt Datensätze mit NULL plain_text_version aus' do
        filter = build_filter(operator: 'contains', value: 'Important')
        result = filter.apply(Note.all, 'Note')
        expect(result).not_to include(note_nil_content)
      end

      it 'escaped LIKE-Wildcards (%) im Suchbegriff' do
        note_percent = build(:note, project: project, organisation: organisation, title: 'Percent', creator: user)
        note_percent.content = 'progress is 100%done'
        note_percent.save!

        filter = build_filter(operator: 'contains', value: '100%done')
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_percent)
        expect(result).not_to include(note_match)
      end

      it 'escaped Unterstriche (_) im Suchbegriff' do
        note_underscore = build(:note, project: project, organisation: organisation, title: 'Underscore', creator: user)
        note_underscore.content = 'file_name_test'
        note_underscore.save!

        filter = build_filter(operator: 'contains', value: 'file_name')
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_underscore)
      end

      it 'gibt leere Ergebnisse bei nicht vorhandenem Suchbegriff' do
        filter = build_filter(operator: 'contains', value: 'xyznonexistent')
        result = filter.apply(Note.all, 'Note')
        expect(result).to be_empty
      end
    end

    describe 'not_contains' do
      it 'schließt Datensätze mit passendem Text aus' do
        filter = build_filter(operator: 'not_contains', value: 'Important')
        result = filter.apply(Note.all, 'Note')
        expect(result).not_to include(note_match)
        expect(result).to include(note_no_match)
      end

      it 'inkludiert Datensätze mit NULL plain_text_version' do
        filter = build_filter(operator: 'not_contains', value: 'Important')
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_nil_content)
      end

      it 'inkludiert Datensätze mit leerer plain_text_version' do
        note_empty_string = build(:note, project: project, organisation: organisation, title: 'EmptyStr', creator: user)
        note_empty_string.content = 'placeholder'
        note_empty_string.save!
        note_empty_string.update_column(:plain_text_version, '')

        filter = build_filter(operator: 'not_contains', value: 'Important')
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_empty_string)
      end

      it 'ist case-insensitive (ILIKE)' do
        filter = build_filter(operator: 'not_contains', value: 'IMPORTANT')
        result = filter.apply(Note.all, 'Note')
        expect(result).not_to include(note_match)
      end
    end

    describe 'equals' do
      it 'findet exakten Match (case-insensitive)' do
        expected_text = note_match.plain_text_version
        filter = build_filter(operator: 'equals', value: expected_text)
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_match)
        expect(result).not_to include(note_no_match)
      end

      it 'findet keinen Partial-Match' do
        filter = build_filter(operator: 'equals', value: 'Important')
        result = filter.apply(Note.all, 'Note')
        expect(result).not_to include(note_match)
      end

      it 'ist case-insensitive via LOWER()' do
        expected_text = note_match.plain_text_version
        filter = build_filter(operator: 'equals', value: expected_text.upcase)
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_match)
      end
    end

    describe 'not_equals' do
      it 'schließt exakten Match aus' do
        expected_text = note_match.plain_text_version
        filter = build_filter(operator: 'not_equals', value: expected_text)
        result = filter.apply(Note.all, 'Note')
        expect(result).not_to include(note_match)
        expect(result).to include(note_no_match)
      end

      it 'inkludiert Datensätze mit NULL plain_text_version' do
        expected_text = note_match.plain_text_version
        filter = build_filter(operator: 'not_equals', value: expected_text)
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_nil_content)
      end

      it 'inkludiert Datensätze mit leerer plain_text_version' do
        note_empty_string = build(:note, project: project, organisation: organisation, title: 'EmptyStr', creator: user)
        note_empty_string.content = 'placeholder'
        note_empty_string.save!
        note_empty_string.update_column(:plain_text_version, '')

        filter = build_filter(operator: 'not_equals', value: 'anything')
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_empty_string)
      end
    end

    # starts_with and ends_with are not allowed in the field_config for 'content',
    # but the filter handles them anyway. We test with skip_validation.
    describe 'starts_with' do
      it 'findet Datensätze die mit Suchbegriff beginnen' do
        filter = build_filter(operator: 'starts_with', value: 'This contains', skip_validation: true)
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_match)
        expect(result).not_to include(note_no_match)
      end

      it 'ist case-insensitive' do
        filter = build_filter(operator: 'starts_with', value: 'this CONTAINS', skip_validation: true)
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_match)
      end
    end

    describe 'ends_with' do
      it 'findet Datensätze die mit Suchbegriff enden' do
        filter = build_filter(operator: 'ends_with', value: 'the project', skip_validation: true)
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_match)
        expect(result).not_to include(note_no_match)
      end

      it 'ist case-insensitive' do
        filter = build_filter(operator: 'ends_with', value: 'THE PROJECT', skip_validation: true)
        result = filter.apply(Note.all, 'Note')
        expect(result).to include(note_match)
      end
    end

    describe 'unsupported operator' do
      it 'gibt die Query unverändert zurück' do
        filter = build_filter(operator: 'regex_match', value: 'test', skip_validation: true)
        result_ids = filter.apply(Note.all, 'Note').pluck(:id)
        expect(result_ids).to include(note_match.id, note_no_match.id, note_nil_content.id)
      end

      it 'loggt eine Warnung' do
        filter = build_filter(operator: 'regex_match', value: 'test', skip_validation: true)
        expect(Rails.logger).to receive(:warn).with(/Unsupported text operator 'regex_match'/)
        filter.apply(Note.all, 'Note')
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Path 2: ActionText JOIN (Ticket model)
  # ──────────────────────────────────────────────────────────────
  describe 'ActionText join path (Ticket)' do
    let!(:ticket_match) do
      ticket = create(:ticket, project: project, organisation: organisation, title: 'Match', creator: user)
      ticket.update!(content: 'Bug report with critical details')
      ticket
    end

    let!(:ticket_no_match) do
      ticket = create(:ticket, project: project, organisation: organisation, title: 'NoMatch', creator: user)
      ticket.update!(content: 'Feature request for improvement')
      ticket
    end

    let!(:ticket_no_content) do
      ticket = create(:ticket, project: project, organisation: organisation, title: 'NoContent', creator: user, content: nil)
      ticket.rich_text_content&.destroy
      ticket.reload
      ticket
    end

    describe 'contains' do
      it 'findet Tickets mit passendem Rich-Text-Content' do
        filter = build_filter(operator: 'contains', value: 'critical details')
        result = filter.apply(Ticket.all, 'Ticket')
        expect(result).to include(ticket_match)
        expect(result).not_to include(ticket_no_match)
      end

      it 'ist case-insensitive (ILIKE)' do
        filter = build_filter(operator: 'contains', value: 'CRITICAL DETAILS')
        result = filter.apply(Ticket.all, 'Ticket')
        expect(result).to include(ticket_match)
      end

      it 'schließt Tickets ohne ActionText-Content aus' do
        filter = build_filter(operator: 'contains', value: 'critical')
        result = filter.apply(Ticket.all, 'Ticket')
        expect(result).not_to include(ticket_no_content)
      end

      it 'escaped LIKE-Wildcards im Suchbegriff' do
        ticket_percent = create(:ticket, project: project, organisation: organisation, title: 'Percent', creator: user)
        ticket_percent.update!(content: 'progress 50%done')

        filter = build_filter(operator: 'contains', value: '50%done')
        result = filter.apply(Ticket.all, 'Ticket')
        expect(result).to include(ticket_percent)
        expect(result).not_to include(ticket_match)
      end
    end

    describe 'not_contains' do
      it 'schließt Tickets mit passendem Content aus' do
        filter = build_filter(operator: 'not_contains', value: 'critical')
        result = filter.apply(Ticket.all, 'Ticket')
        expect(result).not_to include(ticket_match)
        expect(result).to include(ticket_no_match)
      end

      it 'inkludiert Tickets ohne ActionText-Content (NULL body)' do
        filter = build_filter(operator: 'not_contains', value: 'critical')
        result = filter.apply(Ticket.all, 'Ticket')
        expect(result).to include(ticket_no_content)
      end
    end

    describe 'equals' do
      it 'vergleicht gegen den rohen ActionText body (inkl. HTML-Serialisierung)' do
        # ActionText stores the body as serialized text (possibly with HTML tags).
        # equals compares directly against this raw value.
        raw_body = ActiveRecord::Base.connection.select_value(
          ActionText::RichText
            .where(record_type: 'Ticket', record_id: ticket_match.id, name: 'content')
            .select('body::text').to_sql
        )

        filter = build_filter(operator: 'equals', value: raw_body)
        result = filter.apply(Ticket.all, 'Ticket')
        expect(result).to include(ticket_match)
        expect(result).not_to include(ticket_no_match)
      end
    end

    describe 'not_equals' do
      it 'schließt exakten Match aus und inkludiert NULL-Content' do
        raw_body = ActiveRecord::Base.connection.select_value(
          ActionText::RichText
            .where(record_type: 'Ticket', record_id: ticket_match.id, name: 'content')
            .select('body::text').to_sql
        )

        filter = build_filter(operator: 'not_equals', value: raw_body)
        result = filter.apply(Ticket.all, 'Ticket')
        expect(result).not_to include(ticket_match)
        expect(result).to include(ticket_no_match)
        expect(result).to include(ticket_no_content)
      end
    end

    describe 'unsupported operator' do
      it 'gibt die Query unverändert zurück und loggt Warnung' do
        filter = build_filter(operator: 'like', value: 'test', skip_validation: true)
        expect(Rails.logger).to receive(:warn).with(/Unsupported text operator 'like'/)
        result_ids = filter.apply(Ticket.all, 'Ticket').pluck(:id)
        expect(result_ids).to include(ticket_match.id, ticket_no_match.id, ticket_no_content.id)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Edge cases & SQL safety
  # ──────────────────────────────────────────────────────────────
  describe 'edge cases' do
    it 'dupliziert keine JOINs bei mehrfacher Anwendung' do
      filter = build_filter(operator: 'contains', value: 'test')
      query = Ticket.all
      first_result = filter.apply(query, 'Ticket')
      second_result = filter.apply(first_result, 'Ticket')

      join_clauses = second_result.to_sql.scan(/LEFT JOIN action_text_rich_texts/).count
      expect(join_clauses).to eq(1)
    end

    it 'verwendet SQL-sicheres Quoting für record_type und field_name im JOIN' do
      filter = build_filter(operator: 'contains', value: 'test')
      sql = filter.apply(Ticket.all, 'Ticket').to_sql
      expect(sql).to include("record_type = 'Ticket'")
      expect(sql).to include("name = 'content'")
    end

    it 'generiert ILIKE (nicht LIKE) für case-insensitive Suche' do
      filter = build_filter(operator: 'contains', value: 'test')
      sql = filter.apply(Note.all, 'Note').to_sql
      expect(sql).to include('ILIKE')
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Path routing
  # ──────────────────────────────────────────────────────────────
  describe 'path routing' do
    it 'wählt plain_text_version-Pfad für Note mit content-Feld' do
      filter = build_filter(operator: 'contains', value: 'test')
      sql = filter.apply(Note.all, 'Note').to_sql
      expect(sql).to include('plain_text_version')
      expect(sql).not_to include('action_text_rich_texts')
    end

    it 'wählt ActionText-JOIN-Pfad für Ticket mit content-Feld' do
      filter = build_filter(operator: 'contains', value: 'test')
      sql = filter.apply(Ticket.all, 'Ticket').to_sql
      expect(sql).to include('action_text_rich_texts')
      expect(sql).not_to include('plain_text_version')
    end
  end
end
