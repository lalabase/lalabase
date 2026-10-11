# frozen_string_literal: true

require 'rails_helper'

# What: which of a view's columns stay READABLE when the width runs out - their
#   value moves under the title instead of being dropped (designer, 07.09.2026,
#   "Spaltenpanel: Anpinnen einbauen").
# Type: model spec over the two stores a view can live in.
# Why: the pins are a list beside the column list, in two places (the reader's
#   base view has a column of its own, a folder keeps them in its display hash).
#   Two stores for one idea drift silently: a folder that forgets its pins looks
#   exactly like a folder whose pins were never set.
RSpec.describe 'pinned columns' do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }

  describe ViewConfiguration do
    subject(:view) do
      described_class.create!(user: user, project: project, view_type: 'tickets',
                              table_columns: %w[number title assignees created_at])
    end

    it 'starts with none: a pin is set by a reader, never by a default' do
      expect(view.pinned_column_keys).to eq([])
    end

    it 'keeps what it is given, as strings' do
      view.update!(pinned_column_keys: %w[assignees])
      expect(view.reload.pinned_column_keys).to eq(%w[assignees])
    end

    # Number and title are pinned by definition (ALWAYS_PINNED), so an entry for
    # them would be a constant stored per view - and one more thing to keep in
    # step when the constant changes.
    it 'refuses an entry for the two columns that are pinned by definition' do
      view.update!(pinned_column_keys: %w[number title assignees])
      expect(view.reload.pinned_column_keys).to eq(%w[assignees])
    end

    # ⚠️ The rule the panel depends on: unticking a column and ticking it again
    # must not cost the reader the pin. The pin is theirs, not a consequence of
    # the tick.
    it 'keeps the pin of a column that is no longer chosen' do
      view.update!(pinned_column_keys: %w[assignees])
      view.update!(ordered_columns: %w[number title created_at])

      expect(view.reload.pinned_column_keys).to eq(%w[assignees])
    end

    # --- the column itself, not the reader in front of it ------------------
    #
    # ⚠️ pinned_column_keys wraps the value in Array(), so it answers [] for a
    # NULL as happily as for a []. That is right for a reader and wrong for a
    # test: it would go on passing if the migration lost its default. So the
    # raw attribute is asserted here, on a row that never set it.
    describe 'the stored column' do
      it 'starts as an empty list, from the migration and not from the factory' do
        fresh = described_class.create!(user: create(:user), project: project, view_type: 'notes')
        expect(fresh.reload.pinned_columns).to eq([])
      end

      it 'persists the list it was given, in order' do
        view.update!(pinned_column_keys: %w[created_at assignees])
        expect(view.reload.pinned_columns).to eq(%w[created_at assignees])
      end

      # The column has no NOT NULL, so a nil can be written - by a data fix, an
      # old row, a bulk update. The reader has to survive it rather than blow up
      # in the middle of rendering a list.
      it 'reads a NULL as no pins instead of raising' do
        view.update_column(:pinned_columns, nil)
        expect(view.reload.pinned_column_keys).to eq([])
      end
    end

    # --- the whitelist, from the constant --------------------------------
    describe 'the two columns that are pinned by definition' do
      described_class::ALWAYS_PINNED.each do |always|
        it "never stores an entry for #{always.inspect}" do
          view.update!(pinned_column_keys: [always, 'assignees'])
          expect(view.reload.pinned_column_keys).to eq(%w[assignees])
        end
      end

      it 'is the same list the picker treats as fixed' do
        # Two constants naming the same two columns is one place too many to
        # keep in step; this is the assertion that notices when they part.
        expect(described_class::ALWAYS_PINNED).to eq(described_class::DEFAULT_REQUIRED_COLUMNS)
      end
    end

    it 'stores a repeated key once' do
      view.update!(pinned_column_keys: %w[assignees assignees created_at])
      expect(view.reload.pinned_column_keys).to eq(%w[assignees created_at])
    end

    # --- isolation --------------------------------------------------------
    #
    # The view is unique per user, project and view_type, so the same reader
    # pins different columns in two projects, and different columns in the
    # ticket list than in the notes list. A scope lost from the index would let
    # one of these overwrite the other.
    it 'keeps the pins of another project apart' do
      other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      view.update!(pinned_column_keys: %w[assignees])
      other = described_class.create!(user: user, project: other_project, view_type: 'tickets',
                                      pinned_column_keys: %w[created_at])

      expect(view.reload.pinned_column_keys).to eq(%w[assignees])
      expect(other.reload.pinned_column_keys).to eq(%w[created_at])
    end

    it 'keeps the pins of another view type apart' do
      view.update!(pinned_column_keys: %w[assignees])
      notes = described_class.create!(user: user, project: project, view_type: 'notes',
                                      pinned_column_keys: %w[created_at])

      expect(view.reload.pinned_column_keys).to eq(%w[assignees])
      expect(notes.reload.pinned_column_keys).to eq(%w[created_at])
    end

    # --- defense in depth --------------------------------------------------
    #
    # The uniqueness lives twice: as a model validation and as a unique index.
    # Tested through the model alone, the pair looks like one rule, and the day
    # somebody calls the validation redundant the database is the only thing
    # left - which is exactly what must still hold.
    describe 'one view per reader, project and type' do
      before { view } # the lazy subject is the FIRST one; without it there is no clash

      it 'is refused by the model, with the error on the field' do
        second = described_class.new(user: user, project: project, view_type: 'tickets')

        expect(second).not_to be_valid
        expect(second.errors[:user_id]).to be_present
      end

      it 'is refused by the database when the validation is bypassed' do
        second = described_class.new(user: user, project: project, view_type: 'tickets',
                                     organisation: organisation)

        expect { second.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end

    # A view belongs to its project and has no life of its own; the pins go
    # with it. Without dependent: :destroy a deleted project would leave rows
    # behind that no reader can ever reach.
    it 'goes when its project goes, and takes its pins with it' do
      view.update!(pinned_column_keys: %w[assignees])

      expect { project.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  describe SmartFolder do
    subject(:folder) do
      create(:smart_folder, user: user, organisation: organisation, project: project,
                            target_object_type: 'Ticket',
                            display_columns: { 'table_columns' => %w[number title assignees created_at] })
    end

    it 'stores them in the same hash as its columns, because they belong to the same view' do
      folder.update!(pinned_column_keys: %w[created_at])

      expect(folder.reload.pinned_column_keys).to eq(%w[created_at])
      expect(folder.display_columns['table_columns']).to eq(%w[number title assignees created_at])
    end

    # ⚠️ The hash is validated against an allowlist. pinned_columns had to be
    # admitted there; without it every save came back "Konnte nicht speichern"
    # and the reason stood only in the log (user, 07.09.2026).
    it 'is a key the folder admits' do
      folder.display_columns = { 'table_columns' => %w[number title], 'pinned_columns' => %w[assignees] }
      expect(folder).to be_valid
    end

    it 'refuses a pin list that is not a list' do
      folder.display_columns = { 'table_columns' => %w[number title], 'pinned_columns' => 'assignees' }

      expect(folder).not_to be_valid
      expect(folder.errors[:display_columns]).to be_present
    end

    # ⚠️ Iterated over the CONSTANT, not over a list typed here: a spec with its
    # own copy of the allowlist goes green when a key is dropped from the model,
    # because both sides were changed by the same hand. This way a key that
    # leaves the constant takes its example with it, and a key that is added
    # without being accepted turns red on the next run.
    describe 'the keys its configuration hash admits' do
      described_class::DISPLAY_COLUMN_KEYS.each do |key|
        it "accepts #{key.inspect}" do
          folder.display_columns = { 'table_columns' => %w[number title], key => [] }
          expect(folder).to be_valid
        end
      end

      ['pinned', 'PINNED_COLUMNS', 'pinned_columns ', 'columns'].each do |unknown|
        it "refuses #{unknown.inspect}" do
          folder.display_columns = { 'table_columns' => %w[number title], unknown => [] }

          expect(folder).not_to be_valid
          expect(folder.errors[:display_columns].join).to include(unknown.strip)
        end
      end
    end

    # Two folders of two organisations pin what they like; the tenant scope is
    # what keeps them apart, and a folder is read by id from a tenanted scope.
    it 'keeps the pins of another organisation apart' do
      folder.update!(pinned_column_keys: %w[assignees])
      other_org = create(:organisation)

      ActsAsTenant.with_tenant(other_org) do
        other_user = create(:user)
        other_project = create(:project, organisation: other_org)
        other = create(:smart_folder, user: other_user, organisation: other_org, project: other_project,
                                      target_object_type: 'Ticket',
                                      display_columns: { 'table_columns' => %w[number title],
                                                         'pinned_columns' => %w[created_at] })
        expect(other.pinned_column_keys).to eq(%w[created_at])
      end

      expect(folder.reload.pinned_column_keys).to eq(%w[assignees])
    end

    # The writer rebuilds the whole hash. If it ever forgot to carry the column
    # list across, a reader would set a pin and lose their columns - the kind of
    # loss nobody connects to the click that caused it.
    it 'does not lose the column list when only a pin is written' do
      expect { folder.update!(pinned_column_keys: %w[assignees]) }
        .not_to(change { folder.reload.display_columns['table_columns'] })
    end

    # A folder without a list of its own follows the reader's base view, pins
    # and all: nil says "ask the base view", [] would say "this folder pins
    # nothing" and would silently drop the reader's own.
    it 'answers nil while it has no columns of its own' do
      plain = create(:smart_folder, user: user, organisation: organisation, project: project,
                                    target_object_type: 'Ticket')
      expect(plain.pinned_column_keys).to be_nil
    end
  end
end
