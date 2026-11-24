# frozen_string_literal: true

# == Schema Information
#
# Table name: tags
#
#  id              :uuid             not null, primary key
#  name            :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid
#
# Indexes
#
#  index_tags_on_name_and_organisation_id  (name,organisation_id) UNIQUE
#  index_tags_on_organisation_id           (organisation_id)
#  index_tags_on_user_id                   (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
class Tag < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :organisation

  has_many :taggings, dependent: :destroy
  has_many :notes, through: :taggings, source: :taggable, source_type: 'Note'
  has_many :documents, through: :taggings, source: :taggable, source_type: 'Document'
  has_many :tickets, through: :taggings, source: :taggable, source_type: 'Ticket'
  has_many :time_sessions, through: :taggings, source: :taggable, source_type: 'TimeSession'

  # Tags applied (via taggings) to a Note, Document or Ticket that lives in one of the
  # given projects. Scopes the tag vocabulary to a user's accessible projects without a
  # project_id column on tags. Accepts an array of ids or an AR relation (used as a
  # subquery). An empty array yields an empty relation (avoids a SQL "IN ()").
  scope :used_in_projects, lambda { |project_ids|
    if project_ids.is_a?(Array) && project_ids.empty?
      none
    else
      tag_ids = Tagging
                .where(taggable_type: 'Note', taggable_id: Note.where(project_id: project_ids).select(:id))
                .or(Tagging.where(taggable_type: 'Document',
                                  taggable_id: Document.where(project_id: project_ids).select(:id)))
                .or(Tagging.where(taggable_type: 'Ticket',
                                  taggable_id: Ticket.where(project_id: project_ids).select(:id)))
                .select(:tag_id)
      where(id: tag_ids)
    end
  }

  # The longest name a tag may be given where a name is typed freely (the bulk
  # change). Older tags may be longer; they are not touched.
  MAX_NAME_LENGTH = 30
  # A comma separates names wherever a tag list is a string (Taggable#tag_list=).
  NAME_SEPARATOR = ','

  # The one spelling of a tag name: two tags differing only in case or
  # surrounding blanks are the same tag.
  def self.normalize_name(name)
    name.to_s.strip.downcase
  end

  # Whether a name, normalized, may be given to a new tag.
  def self.acceptable_new_name?(name)
    name_problem(name).nil?
  end

  # What keeps a typed name, normalized, from being a tag's: :blank, :separator
  # (a comma would split it into two names) or :too_long; nil when nothing does.
  # One rule for a new tag (the bulk change) and a new name (Actors::RenameTag).
  def self.name_problem(name)
    name = normalize_name(name)
    return :blank if name.blank?
    return :separator if name.include?(NAME_SEPARATOR)

    :too_long if name.length > MAX_NAME_LENGTH
  end

  validates :name, presence: true, uniqueness: { scope: :organisation_id }
  validates :organisation, presence: true

  before_save :normalize_name

  def normalize_name
    self.name = self.class.normalize_name(name) if name.present?
  end

  # The kinds of entries a tag hangs on, in the order the tag list shows them
  # (Organisations::TagsController), each with the column .with_usage_counts reads
  # its number into. `uses_count` is the sum of them.
  USAGE_COLUMNS = {
    'Ticket' => :tickets_count,
    'Note' => :notes_count,
    'Document' => :documents_count,
    'TimeSession' => :time_sessions_count
  }.freeze

  # One row per tag, so the list counts in the query that reads its page: a lateral
  # aggregate over the tag's taggings (index_taggings_on_tag_and_type). A deleted
  # time entry keeps its taggings and is counted nowhere (TimeSession's default
  # scope hides it everywhere else). Join and select are written out instead of
  # built from USAGE_COLUMNS: fixed texts, nothing interpolated into SQL;
  # spec/models/tag_spec.rb holds the three together.
  USAGE_JOIN = <<~SQL.squish.freeze
    LEFT JOIN LATERAL (
      SELECT COUNT(*) FILTER (WHERE taggings.taggable_type = 'Ticket') AS tickets_count,
             COUNT(*) FILTER (WHERE taggings.taggable_type = 'Note') AS notes_count,
             COUNT(*) FILTER (WHERE taggings.taggable_type = 'Document') AS documents_count,
             COUNT(*) FILTER (WHERE taggings.taggable_type = 'TimeSession') AS time_sessions_count,
             COUNT(*) AS uses_count
      FROM taggings
      LEFT JOIN time_sessions ON taggings.taggable_type = 'TimeSession' AND time_sessions.id = taggings.taggable_id
      WHERE taggings.tag_id = tags.id AND time_sessions.deleted_at IS NULL
    ) tag_usage ON TRUE
  SQL

  USAGE_SELECT = 'tags.*, tag_usage.tickets_count, tag_usage.notes_count, tag_usage.documents_count, ' \
                 'tag_usage.time_sessions_count, tag_usage.uses_count'

  # Every tag of the relation with the number of entries it hangs on, per kind
  # (USAGE_COLUMNS) and in all (uses_count), readable as attributes of the rows.
  def self.with_usage_counts
    joins(USAGE_JOIN).select(USAGE_SELECT)
  end

  def self.counts_by_type(taggable_type)
    joins(:taggings)
      .where(taggings: { taggable_type: taggable_type })
      .group(:id)
      .order('COUNT(taggings.id) DESC')
      .count
  end
end
