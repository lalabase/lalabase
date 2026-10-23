# frozen_string_literal: true

# == Schema Information
#
# Table name: documents
#
#  id                 :uuid             not null, primary key
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  creator_id         :uuid             not null
#  current_version_id :uuid
#  organisation_id    :uuid             not null
#  project_id         :uuid             not null
#
# Indexes
#
#  index_documents_on_creator_id          (creator_id)
#  index_documents_on_current_version_id  (current_version_id)
#  index_documents_on_organisation_id     (organisation_id)
#  index_documents_on_project_id          (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (current_version_id => document_versions.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#

class Document < ApplicationRecord
  # Trackable removed - we only want project activities

  acts_as_tenant(:organisation)
  include OneLineText
  belongs_to :project
  belongs_to :creator, class_name: 'User'
  belongs_to :current_version, class_name: 'DocumentVersion', optional: true
  has_many :document_versions, dependent: :destroy

  # The number the next version gets: one more than the highest so far, 1 for a
  # document without one (doc/dokumentansicht_plan.md, S1). Read under the
  # document's row lock (lock!) inside the writer's transaction: that is what
  # keeps two uploads, or an upload and the stock's numbering, from reading the
  # same maximum. Actors::SaveDocumentVersion and Documents::NumberVersions both
  # take it; the unique index on (document_id, number) is the last line behind
  # it, not the plan. A new document (Actors::SaveDocument) has no sibling to
  # race and takes none.
  def next_version_number
    document_versions.maximum(:number).to_i + 1
  end
  accepts_nested_attributes_for :document_versions, allow_destroy: true

  # Tagging System
  include Taggable
  attr_accessor :tag_list_updated

  # Wiki: linkable from a note via an @-mention (ActionText::Attachable).
  include Wiki::Mentionable

  after_create_commit :track_document_created_in_project

  def title
    current_version&.title
  end

  # The title as ONE line, cut to `max` (OneLineText), for the assistant's
  # reference chip and system prompt. ⚠️ Never blank: #title is nil without a
  # current version, and a blank label is a marker the panel walks past
  # (pageContexts() wants id, type and label), i.e. a page that offers nothing
  # and says nothing. The fallback is a word, translated, not the empty string.
  def one_line_title(max:)
    one_line(title.presence || I18n.t('models.document.untitled'), max:)
  end

  def description
    current_version&.description
  end

  # Delegate title/description to the current version. update! (not update): a
  # validation failure (e.g. a blank title) must raise so the actor maps it to a
  # failure Result — the non-bang variant swallowed it and the controller then
  # reported a fake success (D6). The guard keeps the create error path safe: on
  # an unsaved document (build) current_version is nil, so the setter is a no-op.
  def title=(value)
    return unless current_version

    current_version.update!(title: value)
  end

  def description=(value)
    return unless current_version

    current_version.update!(description: value)
  end

  private

  # Track document creation in project activities
  def track_document_created_in_project
    project.track_document_created(self) if project.respond_to?(:track_document_created)
  end
end
