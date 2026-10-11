# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_relations
#
#  id               :uuid             not null, primary key
#  delay_days       :integer
#  relation_type    :integer          not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  organisation_id  :uuid             not null
#  source_ticket_id :uuid             not null
#  target_ticket_id :uuid             not null
#
# Indexes
#
#  index_ticket_relations_on_organisation_id    (organisation_id)
#  index_ticket_relations_on_source_and_type    (source_ticket_id,relation_type)
#  index_ticket_relations_on_target_and_type    (target_ticket_id,relation_type)
#  index_ticket_relations_single_edge_per_pair  (LEAST(source_ticket_id, target_ticket_id), GREATEST(source_ticket_id, target_ticket_id), relation_type) UNIQUE WHERE (relation_type = ANY (ARRAY[1, 2]))
#  index_ticket_relations_unique_edge           (source_ticket_id,target_ticket_id,relation_type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (source_ticket_id => tickets.id) ON DELETE => cascade
#  fk_rails_...  (target_ticket_id => tickets.id) ON DELETE => cascade
#
require 'rails_helper'

# Typed relations between two tickets (doc/ticket_relations_plan.md, revision 4, §3).
# The model rules one by one, the database constraints behind them (raw inserts past the
# model), and what deleting a ticket or a project does to its relations. The tenant
# boundary lives in ticket_relation_tenant_boundary_spec.rb (CI guard list).
RSpec.describe TicketRelation, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket_a) { create(:ticket, project: project) }
  let(:ticket_b) { create(:ticket, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def relation(source, target, type, delay_days: nil)
    described_class.new(source_ticket: source, target_ticket: target, relation_type: type, delay_days: delay_days)
  end

  def base_error?(record, key)
    record.validate
    record.errors.added?(:base, key)
  end

  describe 'relation types' do
    it 'keeps the stored integers fixed (hash-form enum, the index predicate and the check spell them out)' do
      expect(described_class.relation_types).to eq('blocks' => 0, 'relates_to' => 1, 'duplicates' => 2, 'precedes' => 3)
    end

    it 'names the types with one edge per pair and the waiting types' do
      expect(described_class::SINGLE_EDGE_TYPES).to eq(%w[relates_to duplicates])
      expect(described_class::WAITING_TYPES).to eq(%w[blocks precedes])
    end

    it 'turns an unknown type into a validation error instead of an ArgumentError' do
      record = relation(ticket_a, ticket_b, 'depends_on')

      expect(record).not_to be_valid
      expect(record.errors[:relation_type]).to be_present
    end

    it 'maps the seven labels onto the four stored types, flipping the reverse ones' do
      expect(described_class::KINDS).to eq(
        'blocks' => { relation_type: 'blocks', flipped: false },
        'blocked_by' => { relation_type: 'blocks', flipped: true },
        'relates_to' => { relation_type: 'relates_to', flipped: false },
        'duplicates' => { relation_type: 'duplicates', flipped: false },
        'duplicated_by' => { relation_type: 'duplicates', flipped: true },
        'precedes' => { relation_type: 'precedes', flipped: false },
        'follows' => { relation_type: 'precedes', flipped: true }
      )
    end
  end

  describe 'validations' do
    it 'accepts a relation between two tickets of one project' do
      expect(relation(ticket_a, ticket_b, :blocks)).to be_valid
    end

    it 'accepts a relation across two projects of the same organisation' do
      elsewhere = create(:ticket, project: other_project)

      expect(relation(ticket_a, elsewhere, :blocks)).to be_valid
    end

    it 'rejects a ticket related to itself (not_self_referential)' do
      expect(base_error?(relation(ticket_a, ticket_a, :relates_to), :self_reference)).to be(true)
    end

    # Review finding (30.09.2026): with an unsaved ticket both ids are still nil, the id
    # comparison saw nothing, and saving created the ticket first and then hit the CHECK.
    it 'rejects the same unsaved ticket on both ends, before the database check would' do
      draft = build(:ticket, project: project, organisation: organisation)
      record = relation(draft, draft, :blocks)

      expect(base_error?(record, :self_reference)).to be(true)
      expect(record.save).to be(false)
    end

    # Review round 2: the relation was built while its source was unsaved, the ticket was
    # saved afterwards, and the same ticket was then set as target by id.
    it 'rejects a ticket saved after the relation was built and then set as the other end too' do
      draft = build(:ticket, project: project, organisation: organisation)
      record = described_class.new(source_ticket: draft, relation_type: :blocks)
      draft.save!
      record.target_ticket_id = draft.id

      expect(base_error?(record, :self_reference)).to be(true)
      expect(record.save).to be(false)
    end

    it 'rejects the exact same relation twice' do
      relation(ticket_a, ticket_b, :blocks).save!

      expect(base_error?(relation(ticket_a, ticket_b, :blocks), :duplicate)).to be(true)
    end

    it 'accepts two different types on the same pair (A blocks B and A precedes B)' do
      relation(ticket_a, ticket_b, :blocks).save!

      expect(relation(ticket_a, ticket_b, :precedes)).to be_valid
    end

    it 'counts one edge per pair and type: relates_to and duplicates may share a pair' do
      relation(ticket_a, ticket_b, :relates_to).save!

      expect(relation(ticket_b, ticket_a, :duplicates)).to be_valid
    end

    # Review step 2 (30.09.2026): an update turned relates_to into blocks and closed a cycle,
    # past the lock and the cycle check, which only guard the create in the actor.
    it 'keeps the ends and the type of a saved relation; a new one goes through the actor' do
      saved = relation(ticket_a, ticket_b, :precedes, delay_days: 1)
      saved.save!

      expect { saved.relation_type = :blocks }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { saved.source_ticket_id = ticket_b.id }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { saved.target_ticket = ticket_a }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(saved.reload.update(delay_days: 4)).to be(true)
    end

    it 'does not count the record itself as its own duplicate when saved again' do
      saved = relation(ticket_a, ticket_b, :relates_to)
      saved.save!

      expect(saved).to be_valid
    end

    described_class::SINGLE_EDGE_TYPES.each do |type|
      it "rejects the reverse direction for #{type} (one edge per pair)" do
        relation(ticket_a, ticket_b, type).save!

        expect(base_error?(relation(ticket_b, ticket_a, type), :reverse_exists)).to be(true)
      end
    end

    described_class::WAITING_TYPES.each do |type|
      it "leaves the reverse direction of #{type} to the cycle check (the model accepts it)" do
        relation(ticket_a, ticket_b, type).save!

        expect(relation(ticket_b, ticket_a, type)).to be_valid
      end
    end

    describe 'delay_days' do
      [3, 0, -2].each do |days|
        it "accepts a delay of #{days} on precedes" do
          expect(relation(ticket_a, ticket_b, :precedes, delay_days: days)).to be_valid
        end
      end

      (described_class.relation_types.keys - ['precedes']).each do |type|
        it "rejects a delay on #{type}, zero included" do
          expect(base_error?(relation(ticket_a, ticket_b, type, delay_days: 0), :delay_only_for_precedes)).to be(true)
        end

        it "accepts #{type} without a delay" do
          expect(relation(ticket_a, ticket_b, type)).to be_valid
        end
      end

      it 'rejects a fraction' do
        record = relation(ticket_a, ticket_b, :precedes, delay_days: '1.5')

        expect(record).not_to be_valid
        expect(record.errors[:delay_days]).to be_present
      end

      it 'rejects a number the integer column cannot hold, instead of raising on save' do
        record = relation(ticket_a, ticket_b, :precedes, delay_days: 2**31)

        expect(record).not_to be_valid
        expect(record.errors[:delay_days]).to be_present
      end

      # Review round 3 (30.09.2026): the German message was a "Translation missing".
      %i[de en].each do |locale|
        it "says in #{locale} that the number is out of range" do
          I18n.with_locale(locale) do
            record = relation(ticket_a, ticket_b, :precedes, delay_days: 2**31)
            record.validate

            expect(record.errors[:delay_days])
              .to eq([I18n.t('activerecord.errors.models.ticket_relation.attributes.delay_days.in')])
          end
        end
      end
    end
  end

  describe 'tickets' do
    it 'reads the relation from both ends' do
      saved = relation(ticket_a, ticket_b, :blocks)
      saved.save!

      expect(ticket_a.outgoing_relations).to contain_exactly(saved)
      expect(ticket_b.incoming_relations).to contain_exactly(saved)
      expect(ticket_a.incoming_relations).to be_empty
    end

    # Review round 2 (30.09.2026): with inverse_of on the belongs_to, a relation that was only
    # built sat in the ticket's association and stayed there after a failed save. The next save
    # of that ticket wrote it, past the lock and the cycle check of the actor.
    it 'leaves the tickets alone when a relation is only built or rejected' do
      saved = relation(ticket_a, ticket_b, :blocks)
      saved.save!
      expect(relation(ticket_a, ticket_b, :blocks).save).to be(false)
      relation(ticket_b, ticket_a, :blocks) # valid, but never saved: the actor refused it

      expect(ticket_a.outgoing_relations.to_a).to eq([saved])
      expect(ticket_b.outgoing_relations.to_a).to be_empty
      expect do
        ticket_a.save!
        ticket_b.save!
      end.not_to change(described_class, :count)
    end

    it 'does not keep an unsaved ticket from saving' do
      draft = build(:ticket, project: project, organisation: organisation)
      described_class.new(source_ticket: draft, relation_type: :blocks)

      expect(draft.save).to be(true)
    end

    it 'keeps no history: no Trackable, and the tickets are not touched' do
      expect(described_class.ancestors).not_to include(Trackable)

      before_a = ticket_a.reload.updated_at
      before_b = ticket_b.reload.updated_at
      travel 1.minute do
        relation(ticket_a, ticket_b, :blocks).save!
      end

      expect(ticket_a.reload.updated_at).to eq(before_a)
      expect(ticket_b.reload.updated_at).to eq(before_b)
    end
  end

  describe 'deleting' do
    let(:ticket_c) { create(:ticket, project: project) }

    it 'removes the relations on both sides when a ticket is destroyed' do
      relation(ticket_a, ticket_b, :blocks).save!
      relation(ticket_c, ticket_b, :relates_to).save!
      relation(ticket_c, ticket_a, :precedes).save!

      ticket_b.destroy!

      expect(described_class.pluck(:source_ticket_id, :target_ticket_id)).to eq([[ticket_c.id, ticket_a.id]])
    end

    it 'cascades in the database too, past Ticket#destroy' do
      relation(ticket_a, ticket_b, :blocks).save!
      relation(ticket_b, ticket_c, :duplicates).save!

      Ticket.where(id: ticket_b.id).delete_all

      expect(described_class.count).to eq(0)
    end

    # One ticket in the destroyed project: Project#destroy loads each ticket's own
    # dependents one by one, which Prosopite reports from the second ticket on.
    it 'removes relations into other projects when a project is destroyed' do
      elsewhere = create(:ticket, project: other_project)
      relation(ticket_a, elsewhere, :blocks).save!
      relation(elsewhere, ticket_a, :relates_to).save!

      project.destroy!

      expect(described_class.count).to eq(0)
      expect(Ticket.exists?(elsewhere.id)).to be(true)
    end
  end

  describe 'database constraints (raw inserts past the model)' do
    # `overrides` replaces single column values, nil included, past everything the model checks.
    def raw_insert(source, target, type, delay_days: nil, **overrides)
      values = { organisation_id: organisation.id, source_ticket_id: source.id, target_ticket_id: target.id,
                 relation_type: described_class.relation_types.fetch(type.to_s), delay_days: delay_days }.merge(overrides)
      sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, *values.values])
        INSERT INTO ticket_relations
          (organisation_id, source_ticket_id, target_ticket_id, relation_type, delay_days, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, NOW(), NOW())
      SQL
      # A savepoint, so a rejected insert does not poison the example's transaction.
      ActiveRecord::Base.transaction(requires_new: true) { ActiveRecord::Base.connection.execute(sql) }
    end

    it 'rejects a ticket related to itself' do
      expect { raw_insert(ticket_a, ticket_a, :blocks) }.to raise_error(ActiveRecord::CheckViolation)
    end

    it 'rejects the exact same relation twice' do
      raw_insert(ticket_a, ticket_b, :blocks)

      expect { raw_insert(ticket_a, ticket_b, :blocks) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    described_class::SINGLE_EDGE_TYPES.each do |type|
      it "rejects the reverse direction for #{type}" do
        raw_insert(ticket_a, ticket_b, type)

        expect { raw_insert(ticket_b, ticket_a, type) }.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end

    it 'accepts relates_to and duplicates on the same pair, also reversed (the index key holds the type)' do
      raw_insert(ticket_a, ticket_b, :relates_to)

      expect { raw_insert(ticket_b, ticket_a, :duplicates) }.not_to raise_error
    end

    described_class::WAITING_TYPES.each do |type|
      it "accepts the reverse direction for #{type} (only the cycle check refuses it)" do
        raw_insert(ticket_a, ticket_b, type)

        expect { raw_insert(ticket_b, ticket_a, type) }.not_to raise_error
      end
    end

    it 'rejects a delay on any type but precedes' do
      (described_class.relation_types.keys - ['precedes']).each do |type|
        expect { raw_insert(ticket_a, ticket_b, type, delay_days: 0) }.to raise_error(ActiveRecord::CheckViolation), type
      end
    end

    it 'accepts a delay on precedes' do
      expect { raw_insert(ticket_a, ticket_b, :precedes, delay_days: -4) }.not_to raise_error
    end

    it 'rejects a target ticket that does not exist' do
      ghost = Ticket.new(id: SecureRandom.uuid)

      expect { raw_insert(ticket_a, ghost, :blocks) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it 'rejects a source ticket that does not exist' do
      ghost = Ticket.new(id: SecureRandom.uuid)

      expect { raw_insert(ghost, ticket_b, :blocks) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it 'rejects an organisation that does not exist' do
      expect { raw_insert(ticket_a, ticket_b, :blocks, organisation_id: SecureRandom.uuid) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end

    %i[organisation_id source_ticket_id target_ticket_id relation_type].each do |column|
      it "rejects a row without #{column}" do
        expect { raw_insert(ticket_a, ticket_b, :blocks, column => nil) }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end
  end
end
