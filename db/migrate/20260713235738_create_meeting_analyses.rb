# frozen_string_literal: true

# Slice 7a: AI analyses of a meeting with a selectable prompt. Visibility follows
# the Post pattern (is_private + visible_to_user_id, E17) — new analyses start
# PRIVATE and can be published explicitly. prompt_title AND prompt_snapshot are
# both frozen snapshots so the display title and the LLM input survive a prompt
# edit/deletion (Reference target_title_snapshot pattern). The embedding pipeline
# columns are laid down now but stay UI-less until Slice 7b (the create_embeddings-
# without-UI pattern from Slice 1a→6). NO plain_text_version column — a method on
# the model reads `content` (Ticket pattern).
class CreateMeetingAnalyses < ActiveRecord::Migration[8.0]
  def change
    create_table :meeting_analyses, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true, index: false
      t.references :meeting, type: :uuid, null: false, foreign_key: true, index: false
      # creator/analysis_prompt/visible_to_user all nullify — the analysis (and its
      # snapshot) outlives an author deletion or a prompt deletion.
      t.references :creator, type: :uuid, null: true,
                             foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :analysis_prompt, type: :uuid, null: true,
                                     foreign_key: { on_delete: :nullify }
      t.references :visible_to_user, type: :uuid, null: true,
                                     foreign_key: { to_table: :users, on_delete: :nullify },
                                     index: false
      # Both snapshots (Codex-OV): the display title AND the exact LLM input must
      # survive prompt edits/deletion.
      t.string :prompt_title, null: false
      t.text :prompt_snapshot, null: false
      t.text :content, null: false, default: ''
      # Post-pattern visibility (E17): default PRIVATE — prove-then-publish.
      t.boolean :is_private, null: false, default: true
      # Search opt-in (Slice 7b UI); a private analysis is NEVER embedded (E18).
      t.boolean :include_in_search, null: false, default: false
      # Slice-4 status trio: flag = "generation pending", cleared by the service.
      t.boolean :creation_flag, null: false, default: false
      t.text :creation_error, null: false, default: ''
      # Embedding pipeline contract — asymmetric nullable pair, exact column names
      # as Note/Meeting (do NOT harmonise); wired in Slice 7b.
      t.boolean :embeddings_creation_flag, null: true
      t.text :embedding_creation_error, null: true
      t.timestamps
    end

    add_index :meeting_analyses, %i[meeting_id created_at]
    add_index :meeting_analyses, :organisation_id
    # Backs the visible_to(user) filter (Post index_posts_on_privacy pattern).
    add_index :meeting_analyses, %i[is_private visible_to_user_id]
  end
end
