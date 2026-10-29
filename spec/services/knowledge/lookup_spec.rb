# frozen_string_literal: true

require 'rails_helper'

# What: Knowledge::Lookup, the one read of a project's knowledge (notes and documents)
#       by title, shared by the MCP tool search_knowledge and GET /api/v1/projects/:id/knowledge.
# Type: Service spec.
# Why:  Both surfaces must list the same rows for the same reader: per-type policy scoping
#       (no title of a type the reader may not read, not even in `total`), one order
#       (updated_at DESC, id ASC) and a merge over two tables that neither repeats nor loses a
#       row at a page boundary. The options differ by surface on purpose: MCP has always
#       clamped, REST refuses what it cannot read.
RSpec.describe Knowledge::Lookup, :ci_guard do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:role)         { create(:role, organisation: organisation, is_default: true) }

  let(:reader) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  let(:lookup) { described_class.new(user: reader, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant(**areas)
    create(:project_permission, { user: reader, project: project }.merge(areas))
  end

  def note(title, at: nil, id: nil)
    record = create(:note, { project: project, organisation: organisation, title: title, id: id }.compact)
    record.update_columns(updated_at: at) if at
    record
  end

  def document(title, at: nil, id: nil)
    doc = create(:document, { project: project, organisation: organisation, id: id }.compact)
    version = create(:document_version, document: doc, organisation: organisation, title: title)
    doc.update!(current_version: version)
    doc.update_columns(updated_at: at) if at
    doc
  end

  def options(**args)
    described_class.options(args)
  end

  def titles(result)
    result.records.map(&:title)
  end

  describe '.options' do
    context 'lenient (MCP)' do
      it 'reads garbage page and per_page as the defaults and clamps a large per_page' do
        opts = described_class.options({ q: ' Alpha ', page: 'x', per_page: '0' })
        expect(opts).to have_attributes(query: 'Alpha', type: '', page: 1, per_page: described_class::DEFAULT_PER_PAGE)

        expect(described_class.options({ per_page: 10_000 }).per_page).to eq(described_class::MAX_PER_PAGE)
        expect(described_class.options({ page: -3 }).page).to eq(1)
      end

      it 'refuses an unknown type with the MCP wording' do
        expect { described_class.options({ type: 'ticket' }) }
          .to raise_error(described_class::InvalidOption, 'invalid type (expected "note" or "document")')
      end
    end

    context 'strict (REST)' do
      def strict(**args)
        described_class.options(args, strict: true)
      end

      it 'takes absent and blank page and per_page as the defaults' do
        expect(strict).to have_attributes(page: 1, per_page: described_class::DEFAULT_PER_PAGE, query: '', type: '')
        expect(strict(page: '', per_page: '')).to have_attributes(page: 1, per_page: described_class::DEFAULT_PER_PAGE)
      end

      it 'reads whole numbers given as text' do
        expect(strict(page: '2', per_page: '25')).to have_attributes(page: 2, per_page: 25)
      end

      it 'refuses a per_page above the maximum instead of clamping it' do
        expect { strict(per_page: (described_class::MAX_PER_PAGE + 1).to_s) }
          .to raise_error(described_class::InvalidOption, /per_page/)
        expect(strict(per_page: described_class::MAX_PER_PAGE.to_s).per_page).to eq(described_class::MAX_PER_PAGE)
      end

      it 'refuses page and per_page that are not positive whole numbers' do
        ['0', '-1', 'abc', '1.5', ' 2'].each do |value|
          expect { strict(page: value) }.to raise_error(described_class::InvalidOption, /page/), "page #{value.inspect}"
          expect { strict(per_page: value) }.to raise_error(described_class::InvalidOption, /per_page/),
                                                "per_page #{value.inspect}"
        end
      end

      it 'caps page at 100,000 (it bounds the LIMIT of each arm)' do
        expect(described_class::MAX_PAGE).to eq(100_000)
        expect(strict(page: '100000').page).to eq(100_000)
      end

      it 'refuses a NUL in q or type, also at the edges where strip would drop it' do
        ["a\0b", "\0", "a\0"].each do |value|
          expect { strict(q: value) }.to raise_error(described_class::InvalidOption, /q/), "q #{value.inspect}"
        end
        expect { strict(type: "note\0") }.to raise_error(described_class::InvalidOption, /type/)
      end

      it 'refuses a page beyond MAX_PAGE' do
        expect { strict(page: (described_class::MAX_PAGE + 1).to_s) }.to raise_error(described_class::InvalidOption, /page/)
      end

      it 'refuses a list or a nested value' do
        expect { strict(page: ['1']) }.to raise_error(described_class::InvalidOption, /page/)
        expect { strict(q: ['a']) }.to raise_error(described_class::InvalidOption, /q/)
        expect { strict(type: { 'a' => 'note' }) }.to raise_error(described_class::InvalidOption, /type/)
      end
    end
  end

  describe '#page' do
    context 'with read access to both types' do
      before { grant(notes_access: 'read_only', documents_access: 'read_only') }

      it 'without a query lists every note and document, newest first' do
        note('Old note', at: 3.days.ago)
        document('Middle document', at: 2.days.ago)
        note('New note', at: 1.day.ago)

        result = lookup.page(options)

        expect(titles(result)).to eq(['New note', 'Middle document', 'Old note'])
        expect(result.total).to eq(3)
      end

      it 'with a query matches titles only, case-insensitively' do
        note('Deploy runbook')
        document('deploy checklist')
        note('Something else')

        expect(titles(lookup.page(options(q: 'DEPLOY')))).to contain_exactly('Deploy runbook', 'deploy checklist')
      end

      it 'filters by type' do
        note('Shared')
        document('Shared')

        expect(lookup.page(options(q: 'Shared', type: 'document')).records.map(&:class)).to eq([Document])
        expect(lookup.page(options(type: 'note')).records.map(&:class)).to eq([Note])
        expect(lookup.page(options(type: 'note')).total).to eq(1)
      end

      it 'takes %, _ and \\ in the query literally' do
        note('Cost a%b')
        note('axxb')
        note('snake_case')
        note('snakeXcase')
        note('back\\slash')
        note('backslash')

        expect(titles(lookup.page(options(q: 'a%b')))).to eq(['Cost a%b'])
        expect(titles(lookup.page(options(q: 'snake_case')))).to eq(['snake_case'])
        expect(titles(lookup.page(options(q: 'back\\slash')))).to eq(['back\\slash'])
      end

      # Five rows share one updated_at across both tables, with fixed ids so that the id order
      # interleaves the types (d1 n2 d3 n4 n5) and the notes are inserted against it. A per-arm
      # LIMIT without the SQL id tiebreak returns n5, n4 first; a Ruby merge without the id
      # tiebreak puts the note arm before the document arm. Either way page 1 is no longer d1, n2.
      it 'neither repeats nor loses a row at a page boundary with equal updated_at' do
        at = 1.day.ago.change(usec: 0)
        ids = (1..5).index_with { |n| format('00000000-0000-4000-8000-%012d', n) }
        # Setup only: several records from one block read as an N+1 to Prosopite.
        Prosopite.pause do
          note('n5', at: at, id: ids[5])
          note('n4', at: at, id: ids[4])
          note('n2', at: at, id: ids[2])
          document('d3', at: at, id: ids[3])
          document('d1', at: at, id: ids[1])
        end

        first = lookup.page(options(page: 1, per_page: 2))
        second = lookup.page(options(page: 2, per_page: 2))
        third = lookup.page(options(page: 3, per_page: 2))

        expect(titles(first)).to eq(%w[d1 n2])
        expect(titles(second)).to eq(%w[d3 n4])
        expect(titles(third)).to eq(%w[n5])
        expect(third.total).to eq(5)
      end

      # Rows one microsecond apart in one second: SQL orders them by the microseconds, so the
      # merge has to as well. Ids run against the time order, so a merge that compared whole
      # seconds and fell back to the id would turn the order round.
      it 'orders rows within one second by their microseconds' do
        base = 1.day.ago.change(usec: 0)
        Prosopite.pause do
          note('oldest', at: base + 0.000001, id: '00000000-0000-4000-8000-000000000001')
          note('middle', at: base + 0.000002, id: '00000000-0000-4000-8000-000000000002')
          document('newest', at: base + 0.000003, id: '00000000-0000-4000-8000-000000000003')
        end

        first = lookup.page(options(page: 1, per_page: 1))
        second = lookup.page(options(page: 2, per_page: 1))
        third = lookup.page(options(page: 3, per_page: 1))

        expect(titles(first) + titles(second) + titles(third)).to eq(%w[newest middle oldest])
      end

      it 'reads no rows for a page beyond the total, only the counts' do
        note('Only')
        statements = []
        callback = ->(*, payload) { statements << payload[:sql] }

        result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
          lookup.page(options(page: 50, per_page: 10))
        end

        expect(result.records).to eq([])
        expect(result.total).to eq(1)
        expect(statements.grep(/\ASELECT "(notes|documents)"\.\*/)).to be_empty
      end

      # The page right after the last one starts exactly at the total (offset == total).
      it 'reads no rows for the page right after the last one either' do
        note('Only')
        statements = []
        callback = ->(*, payload) { statements << payload[:sql] }

        result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
          lookup.page(options(page: 2, per_page: 1))
        end

        expect(result.records).to eq([])
        expect(statements.grep(/\ASELECT "(notes|documents)"\.\*/)).to be_empty
      end

      it 'returns an empty page beyond the last one, with the full total' do
        note('Only')

        result = lookup.page(options(page: 4, per_page: 2))
        expect(result.records).to eq([])
        expect(result.total).to eq(1)
      end

      it 'serializes a hit with the knowledge link' do
        hit = note('Alpha')

        expect(described_class.serialize(hit)).to eq(
          type: 'note', id: hit.id, title: 'Alpha', updated_at: hit.updated_at.iso8601,
          link: "lalabase://note/#{hit.id}"
        )
      end

      it 'answers in data and meta' do
        note('Alpha')
        result = lookup.page(options(per_page: 5))

        expect(result.to_h).to eq(
          data: result.records.map { |record| described_class.serialize(record) },
          meta: { page: 1, per_page: 5, total: 1 }
        )
      end
    end

    context 'with read access to notes only' do
      before { grant(notes_access: 'read_only', documents_access: 'no_access') }

      it 'never lists a document, neither as a hit nor in total, with or without a query' do
        note('Plan A')
        document('Plan B secret')

        listed = lookup.page(options)
        searched = lookup.page(options(q: 'Plan'))
        documents_only = lookup.page(options(type: 'document'))
        secret = lookup.page(options(q: 'secret'))

        expect([titles(listed), listed.total]).to eq([['Plan A'], 1])
        expect([titles(searched), searched.total]).to eq([['Plan A'], 1])
        expect([documents_only.records, documents_only.total]).to eq([[], 0])
        expect([secret.records, secret.total]).to eq([[], 0])
      end
    end

    context 'with read access to documents only' do
      before { grant(notes_access: 'no_access', documents_access: 'read_only') }

      it 'never lists a note' do
        note('Hidden note')
        document('Visible document')

        result = lookup.page(options)
        expect(titles(result)).to eq(['Visible document'])
        expect(result.total).to eq(1)
      end
    end

    context 'without any knowledge right' do
      before { grant(notes_access: 'no_access', documents_access: 'no_access') }

      it 'answers an empty list, not an error' do
        note('Hidden')
        document('Hidden too')

        result = lookup.page(options)
        expect(result.records).to eq([])
        expect(result.total).to eq(0)
      end
    end

    it 'never lists knowledge of another project of the same organisation' do
      grant(notes_access: 'read_only', documents_access: 'read_only')
      other = create(:project, organisation: organisation)
      create(:project_permission, user: reader, project: other, notes_access: 'read_only')
      create(:note, project: other, organisation: organisation, title: 'Elsewhere')

      expect(lookup.page(options).records).to eq([])
    end
  end
end
