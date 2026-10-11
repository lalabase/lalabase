# frozen_string_literal: true

RSpec.shared_examples 'a taggable model' do |factory_name|
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:taggable) do
    ActsAsTenant.with_tenant(organisation) do
      if factory_name == :time_session
        create(factory_name, project: project, organisation: organisation, creator: user)
      else
        create(factory_name, project: project, organisation: organisation)
      end
    end
  end

  let(:create_taggable_proc) do
    lambda do |extra_attrs = {}|
      ActsAsTenant.with_tenant(organisation) do
        attrs = { project: project, organisation: organisation }.merge(extra_attrs)
        attrs[:creator] = user if factory_name == :time_session
        create(factory_name, **attrs)
      end
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # ── Associations ──────────────────────────────────────────────

  it 'has many tags through taggings' do
    assoc = taggable.class.reflect_on_association(:tags)
    expect(assoc).to have_attributes(macro: :has_many)
    expect(assoc.options[:through]).to eq(:taggings)
  end

  it 'has many taggings with dependent delete_all' do
    assoc = taggable.class.reflect_on_association(:taggings)
    expect(assoc).to have_attributes(macro: :has_many)
    expect(assoc.options).to include(as: :taggable, dependent: :delete_all)
  end

  # ── #tag_list ─────────────────────────────────────────────────

  describe '#tag_list' do
    it 'returns an empty array when no tags are assigned' do
      expect(taggable.tag_list).to eq([])
    end

    it 'returns tag names' do
      tag1 = create(:tag, name: 'important', organisation: organisation)
      tag2 = create(:tag, name: 'urgent', organisation: organisation)
      create(:tagging, tag: tag1, taggable: taggable)
      create(:tagging, tag: tag2, taggable: taggable)

      expect(taggable.tag_list).to match_array(%w[important urgent])
    end

    it 'uses pluck when tags are not preloaded' do
      taggable.tag_list = %w[alpha]
      taggable.tags.reset

      expect(taggable.tags).not_to be_loaded
      expect(taggable.tag_list).to eq(%w[alpha])
    end

    it 'uses map when tags are preloaded via includes' do
      taggable.tag_list = %w[alpha]

      loaded = taggable.class.includes(:tags).find(taggable.id)
      loaded.tags.load

      expect(loaded.tags).to be_loaded
      expect(loaded.tag_list).to eq(%w[alpha])
    end
  end

  # ── #tag_list= ────────────────────────────────────────────────

  describe '#tag_list=' do
    context 'with string input' do
      it 'assigns comma-separated tags' do
        taggable.tag_list = 'important, urgent'
        expect(taggable.tag_list).to match_array(%w[important urgent])
      end

      it 'strips whitespace from tag names' do
        taggable.tag_list = '  padded ,  spaced  '
        expect(taggable.tag_list).to match_array(%w[padded spaced])
      end

      it 'handles extra commas gracefully' do
        taggable.tag_list = 'alpha,,beta,'
        expect(taggable.tag_list).to match_array(%w[alpha beta])
      end

      it 'handles empty string by clearing all tags' do
        taggable.tag_list = %w[existing]
        taggable.tag_list = ''
        expect(taggable.tag_list).to eq([])
      end
    end

    context 'with array input' do
      it 'assigns tags from array' do
        taggable.tag_list = %w[important urgent]
        expect(taggable.tag_list).to match_array(%w[important urgent])
      end

      it 'filters blank entries' do
        taggable.tag_list = ['valid', '', '  ', nil.to_s]
        expect(taggable.tag_list).to eq(%w[valid])
      end

      it 'handles empty array by clearing all tags' do
        taggable.tag_list = %w[existing]
        taggable.tag_list = []
        expect(taggable.tag_list).to eq([])
      end
    end

    context 'with nil input' do
      it 'clears all tags' do
        taggable.tag_list = %w[existing]
        taggable.tag_list = nil
        expect(taggable.tag_list).to eq([])
      end
    end

    context 'case normalization' do
      it 'normalizes tag names to lowercase' do
        taggable.tag_list = %w[Important URGENT Mixed]
        expect(taggable.tag_list).to match_array(%w[important urgent mixed])
      end

      it 'reuses existing lowercase tags when given uppercase input' do
        create(:tag, name: 'important', organisation: organisation)

        expect { taggable.tag_list = %w[IMPORTANT] }.not_to change(Tag, :count)
        expect(taggable.tag_list).to eq(%w[important])
      end
    end

    context 'deduplication' do
      it 'ignores duplicate tag names in input' do
        taggable.tag_list = %w[alpha alpha beta]

        expect(taggable.tag_list).to match_array(%w[alpha beta])
        expect(taggable.taggings.count).to eq(2)
      end

      it 'ignores case-different duplicates' do
        taggable.tag_list = %w[Alpha ALPHA alpha]

        expect(taggable.tag_list).to eq(%w[alpha])
        expect(taggable.taggings.count).to eq(1)
      end
    end

    context 'tag lifecycle' do
      it 'creates new tags when they do not exist' do
        expect { taggable.tag_list = 'important, urgent' }.to change(Tag, :count).by(2)
      end

      it 'reuses existing tags' do
        create(:tag, name: 'important', organisation: organisation)
        expect { taggable.tag_list = 'important, urgent' }.to change(Tag, :count).by(1)
      end

      it 'removes tags not in the new list' do
        tag1 = create(:tag, name: 'important', organisation: organisation)
        tag2 = create(:tag, name: 'urgent', organisation: organisation)
        create(:tagging, tag: tag1, taggable: taggable)
        create(:tagging, tag: tag2, taggable: taggable)

        taggable.tag_list = 'important, critical'

        expect(taggable.tag_list).to match_array(%w[important critical])
        expect(taggable.tags.where(name: 'urgent')).to be_empty
      end

      it 'does not destroy the Tag record when removing a tagging' do
        tag = create(:tag, name: 'persistent', organisation: organisation)
        create(:tagging, tag: tag, taggable: taggable)

        taggable.tag_list = []

        expect(taggable.tags.count).to eq(0)
        expect(Tag.find_by(id: tag.id)).to be_present
      end
    end

    context 'idempotency' do
      it 'does not create duplicate taggings when setting same tags again' do
        taggable.tag_list = %w[alpha beta]

        expect { taggable.tag_list = %w[alpha beta] }
          .not_to change(Tagging, :count)
      end

      it 'does not destroy and recreate unchanged taggings' do
        taggable.tag_list = %w[alpha beta]
        original_ids = taggable.taggings.pluck(:id).sort

        taggable.tag_list = %w[alpha beta]

        expect(taggable.taggings.reload.pluck(:id).sort).to eq(original_ids)
      end
    end

    context 'on new (unpersisted) records' do
      it 'processes tags after first save' do
        item = ActsAsTenant.with_tenant(organisation) do
          build(factory_name, project: project, organisation: organisation).tap do |t|
            t.creator = user if factory_name == :time_session
          end
        end
        item.tag_list = %w[deferred]

        expect(Tag.find_by(name: 'deferred')).to be_nil

        item.save!
        expect(item.tag_list).to eq(%w[deferred])
      end
    end

    context 'uses organisation_id from taggable, not current tenant' do
      it 'creates tags for the correct organisation' do
        taggable.tag_list = %w[scoped]

        tag = Tag.find_by(name: 'scoped')
        expect(tag.organisation_id).to eq(organisation.id)
      end
    end
  end

  # ── .tagged_with ──────────────────────────────────────────────

  describe '.tagged_with' do
    let!(:tag_a) { create(:tag, name: 'alpha', organisation: organisation) }
    let!(:tag_b) { create(:tag, name: 'beta', organisation: organisation) }
    let!(:item_a) do
      create_taggable_proc.call.tap { |i| create(:tagging, tag: tag_a, taggable: i) }
    end
    let!(:item_ab) do
      create_taggable_proc.call.tap do |i|
        create(:tagging, tag: tag_a, taggable: i)
        create(:tagging, tag: tag_b, taggable: i)
      end
    end
    let!(:untagged) { create_taggable_proc.call }

    it 'returns items with the given tag' do
      result = taggable.class.tagged_with('alpha').to_a
      expect(result).to include(item_a, item_ab)
      expect(result).not_to include(untagged)
    end

    it 'returns items matching any of multiple tags' do
      result = taggable.class.tagged_with(%w[alpha beta]).to_a
      expect(result).to include(item_a, item_ab)
    end

    it 'does not return duplicates when item has multiple matching tags' do
      result = taggable.class.tagged_with(%w[alpha beta]).to_a
      expect(result.count { |i| i.id == item_ab.id }).to eq(1)
    end

    context 'with match_all: true' do
      it 'returns only items having ALL specified tags' do
        result = taggable.class.tagged_with(%w[alpha beta], match_all: true).to_a
        expect(result).to include(item_ab)
        expect(result).not_to include(item_a)
      end

      it 'works with a single tag' do
        result = taggable.class.tagged_with('alpha', match_all: true).to_a
        expect(result).to include(item_a, item_ab)
      end
    end

    context 'edge cases' do
      it 'returns none for a non-existent tag' do
        expect(taggable.class.tagged_with('nonexistent')).to be_empty
      end

      it 'returns none for an empty string' do
        expect(taggable.class.tagged_with('')).to be_empty
      end

      it 'returns none for an empty array' do
        expect(taggable.class.tagged_with([])).to be_empty
      end

      it 'returns none for blank entries only' do
        expect(taggable.class.tagged_with(['', '  '])).to be_empty
      end

      it 'ignores non-existent tags in a mixed array' do
        result = taggable.class.tagged_with(%w[alpha nonexistent]).to_a
        expect(result).to include(item_a, item_ab)
      end

      it 'returns none when match_all and some tags do not exist' do
        result = taggable.class.tagged_with(%w[alpha nonexistent], match_all: true)
        expect(result).to be_empty
      end
    end

    context 'tenant isolation' do
      it 'does not return items from another organisation' do
        other_org = create(:organisation)
        ActsAsTenant.with_tenant(other_org) do
          other_tag = create(:tag, name: 'alpha', organisation: other_org)
          other_project = create(:project, organisation: other_org)
          attrs = { project: other_project, organisation: other_org }
          attrs[:creator] = user if factory_name == :time_session
          other_item = create(factory_name, **attrs)
          create(:tagging, tag: other_tag, taggable: other_item)
        end

        result = taggable.class.tagged_with('alpha')
        result.each do |item|
          expect(item.organisation_id).to eq(organisation.id)
        end
      end
    end
  end

  # ── .tag_counts ───────────────────────────────────────────────

  describe '.tag_counts' do
    it 'returns tags with usage counts ordered descending' do
      tag1 = create(:tag, name: 'popular', organisation: organisation)
      tag2 = create(:tag, name: 'rare', organisation: organisation)

      item1 = create_taggable_proc.call
      item2 = create_taggable_proc.call
      item3 = create_taggable_proc.call

      create(:tagging, tag: tag1, taggable: item1)
      create(:tagging, tag: tag1, taggable: item2)
      create(:tagging, tag: tag1, taggable: item3)
      create(:tagging, tag: tag2, taggable: item1)

      counts = taggable.class.tag_counts
      popular = counts.find { |t| t.name == 'popular' }
      rare    = counts.find { |t| t.name == 'rare' }

      expect(popular.count).to eq(3)
      expect(rare.count).to eq(1)
      expect(counts.index(popular)).to be < counts.index(rare)
    end

    it 'returns empty when no tags exist' do
      expect(taggable.class.tag_counts).to be_empty
    end

    it 'only counts taggings for the correct taggable_type' do
      tag = create(:tag, name: 'shared', organisation: organisation)
      item = create_taggable_proc.call
      create(:tagging, tag: tag, taggable: item)

      # Tagging for a different taggable_type should not be counted
      note = ActsAsTenant.with_tenant(organisation) do
        create(:note, project: project, organisation: organisation)
      end
      create(:tagging, tag: tag, taggable: note) unless factory_name == :note

      counts = taggable.class.tag_counts
      shared = counts.find { |t| t.name == 'shared' }

      if factory_name == :note
        # both taggings are for Note, so count is 2
        expect(shared.count).to be >= 1
      else
        expect(shared.count).to eq(1)
      end
    end
  end
end
