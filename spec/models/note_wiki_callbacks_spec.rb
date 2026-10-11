# frozen_string_literal: true

require 'rails_helper'

# What:  Note wiki save-lifecycle callbacks (design D2: invariants in the model).
# Type:  Model spec (DB), tenant-scoped.
# Why:   These callbacks are the UNBYPASSABLE place markdown_body, the GFM guard
#        and versioning hang on (every write path runs through them). Incl. the
#        REGRESSION-CRITICAL case: the existing note save (plain_text) must not break.
# Note:  Since Lane B (Lexxy) the Action Text sanitizer keeps <table>/<thead>/<tbody>/
#        <tr>/<th>/<td>, so the GFM-guard tests run END-TO-END on real table content
#        (no stub): real HTML → sanitizer → callback → validation. This also guards the
#        load-bearing lexxy sanitizer allowlist — if it regressed, tables would be
#        stripped and these tests would fail.
RSpec.describe 'Note wiki callbacks', type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  let(:project) { create(:project, organisation: organisation) }

  def build_note(content)
    build(:note, organisation: organisation, project: project, content: content)
  end

  describe 'markdown_body derivation' do
    it 'derives markdown_body from the content on save' do
      note = build_note('<div>Hello <strong>world</strong></div>')
      note.save!
      expect(note.reload.markdown_body).to include('**world**')
    end
  end

  describe 'wiki columns (defaults as contract)' do
    # Mutation guard: changing the migration default for lock_version turns this red.
    # Asserted on a fresh record (the schema default), NOT via the factory and NOT
    # after create — the create flow does a follow-up UPDATE (tagging/tracking), so a
    # created note already sits at lock_version 1. The contract here is the INSERT default.
    it 'defaults lock_version to 0 (optimistic-locking start value)' do
      expect(Note.new.lock_version).to eq(0)
    end
  end

  describe 'GFM guard (block-in-cell), end-to-end through the real sanitizer' do
    # Intent: the callback turns the serializer exception into a validation error on
    # :content (no silent pass-through, no 500). Real table HTML, no stub — the
    # sanitizer must keep the table for the guard to even see it.
    it 'turns block content in cells into a validation error' do
      note = build_note('<table><tbody><tr><th>K</th></tr><tr><td><ul><li>a</li></ul></td></tr></tbody></table>')
      expect(note.valid?).to be(false)
      expect(note.errors[:content]).to be_present
    end

    # Real Lexxy table HTML (captured from the live editor): a <figure> wrapper and
    # cells whose content is wrapped in <p>. This is the shape that actually reaches the
    # DB, so the guard must accept it (the <p> is unwrapped, not treated as block content).
    it 'lets a real Lexxy table (figure wrapper + <p>-wrapped cells) pass validation' do
      note = build_note('<figure class="lexxy-content__table-wrapper"><table><tbody>' \
                        '<tr><th><p>A</p></th></tr><tr><td><p>1</p></td></tr></tbody></table></figure>')
      expect(note.valid?).to be(true)
    end
  end

  describe 'table content end-to-end (Lane B happy path)' do
    # Intent: a real Lexxy table survives the sanitizer AND becomes a GFM table in
    # markdown_body + a version — the full editor→ActionText→sanitizer→callback chain,
    # using the EXACT HTML Lexxy emits (figure wrapper, <p>-wrapped cells). If the lexxy
    # sanitizer allowlist regressed (table stripped) or the <p>-unwrap broke, this turns red.
    it 'derives a GFM table into markdown_body and snapshots a version' do
      note = build_note('<figure class="lexxy-content__table-wrapper"><table><tbody>' \
                        '<tr><th><p>Task</p></th><th><p>Status</p></th></tr>' \
                        '<tr><td><p>Login</p></td><td><p>open</p></td></tr></tbody></table></figure>')
      note.save!

      # the table survived the sanitizer on the way to the canonical HTML …
      expect(note.content.body.to_html).to include('<table')
      # … and the derived markdown is a GFM table with the header separator row.
      md = note.reload.markdown_body
      expect(md).to include('| Task | Status |')
      expect(md).to match(/\|\s*---\s*\|\s*---\s*\|/)
      expect(md).to include('| Login | open |')
      expect(note.note_versions.count).to eq(1)
    end
  end

  describe 'content-change gating (F5)' do
    # Intent: the GFM guard + markdown derivation only run on a content-changing save.
    # A title-only rename must not re-validate the (unchanged) stored content — otherwise
    # a note whose body predates the guard (imported / future MCP) could no longer be
    # renamed. Mutation guard: dropping the wiki_content_changing? gate turns this red
    # (the stubbed block-in-cell content would fail the validation on the rename).
    it 'does not re-validate unchanged content on a title-only save' do
      note = build_note('<div>valid body</div>')
      note.save!

      allow(note).to receive(:wiki_content_html).and_return(
        '<table><tbody><tr><td><ul><li>x</li></ul></td></tr></tbody></table>'
      )

      expect(note.update(title: 'Renamed')).to be(true)
      expect(note.errors[:content]).to be_empty
    end
  end

  describe 'versioning (D4)' do
    it 'creates a version on the first save' do
      note = build_note('<div>v1</div>')
      expect { note.save! }.to change { NoteVersion.count }.by(1)
    end

    it 'creates no new version when the content is unchanged (dirty trace)' do
      note = build_note('<div>stable</div>')
      note.save!
      expect { note.update!(title: 'New title') }.not_to(change { note.note_versions.count })
    end

    it 'creates a new version when the content changed' do
      note = build_note('<div>old</div>')
      note.save!
      expect { note.update!(content: '<div>new</div>') }.to change { note.note_versions.count }.by(1)
    end

    it 'holds the invariant: current content == latest version' do
      note = build_note('<div>one</div>')
      note.save!
      note.update!(content: '<div>two</div>')
      latest = note.note_versions.chronological.last
      expect(latest.content_hash).to eq(NoteVersion.digest_for(note.content.body.to_html))
    end
  end

  describe 'REGRESSION: the existing note save stays intact' do
    # Intent: the Lexxy-prep rework must not break today's save path.
    it 'saves a plain note and still fills plain_text' do
      note = build_note('Plain text')
      expect(note.save).to be(true)
      note.reload
      expect(note.plain_text_version).to include('Plain text')
      expect(note.plain_text_word_count).to be > 0
      expect(note.markdown_body).to include('Plain text')
    end
  end

  describe 'reference rebuild (D3)' do
    let(:target) { create(:note, organisation: organisation, project: project, title: 'Target') }

    # The remaining tests stub the extractor to drive the callback's bookkeeping
    # (remove / self-skip) without re-asserting attachment internals. The first test below
    # uses NO stub: a real ActionText mention attachment, end-to-end, to prove the actual
    # sgid → MentionResolver → reference + markdown-link chain (the Lane B integration).
    def stub_extractor(returns)
      allow_any_instance_of(Wiki::ReferenceExtractor).to receive(:call).and_return(returns)
    end

    it 'turns a REAL mention attachment into an outgoing reference and a lalabase markdown link' do
      target_note = create(:note, organisation: organisation, project: project, title: 'Target Page')
      mention_html = <<~HTML.squish
        <div>See <action-text-attachment
          sgid="#{target_note.attachable_sgid}"
          content-type="application/vnd.actiontext.mention"></action-text-attachment>.</div>
      HTML
      source = build_note(mention_html)
      source.save!

      ref = source.outgoing_references.sole
      expect(ref.target).to eq(target_note)
      expect(ref.target_title_snapshot).to eq('Target Page')
      expect(source.reload.markdown_body).to include("[Target Page](lalabase:note/#{target_note.id})")
    end

    it 'creates an outgoing reference with a title snapshot for each target' do
      stub_extractor([target])
      source = build_note('<div>mentions target</div>')
      source.save!

      ref = source.outgoing_references.sole
      expect(ref.target).to eq(target)
      expect(ref.target_title_snapshot).to eq('Target')
    end

    it 'removes references once the targets are gone from the content' do
      source = build_note('<div>v1</div>')
      stub_extractor([target])
      source.save!
      expect(source.outgoing_references.count).to eq(1)

      stub_extractor([])
      source.update!(content: '<div>v2</div>')
      expect(source.outgoing_references).to be_empty
    end

    it 'skips a self-mention (no self-reference, no error)' do
      source = create(:note, organisation: organisation, project: project)
      stub_extractor([source])

      expect { source.update!(content: '<div>self mention</div>') }.not_to raise_error
      expect(source.outgoing_references).to be_empty
    end

    # Mutation guard for the wiki_content_changed? gate on the REBUILD path specifically.
    # A title-only save must skip the rebuild. A plain count check would not catch a
    # broken gate (re-extracting the same target keeps the count at 1), so we flip the
    # stub to [] first: if the gate broke and the rebuild ran, it would wipe the
    # reference. The reference SURVIVING proves the rebuild was skipped.
    it 'does not rebuild references on a title-only save' do
      stub_extractor([target])
      source = build_note('<div>mentions target</div>')
      source.save!
      expect(source.outgoing_references.count).to eq(1)

      stub_extractor([])
      source.update!(title: 'Renamed')
      expect(source.outgoing_references.count).to eq(1)
    end

    # Regression for the audit finding: a target title can exceed the snapshot's 255
    # guard (Note#title is unbounded). The snapshot is truncated so a long title never
    # fails the linking note's save. Without the truncate this raises RecordInvalid.
    it 'truncates an over-long target title into the snapshot without failing the save' do
      long_target = create(:note, organisation: organisation, project: project, title: 'x' * 300)
      stub_extractor([long_target])
      source = build_note('<div>mentions a long-titled note</div>')

      expect { source.save! }.not_to raise_error
      expect(source.outgoing_references.sole.target_title_snapshot.length).to be <= 255
    end
  end
end
