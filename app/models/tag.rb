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
    name = normalize_name(name)
    name.present? && name.length <= MAX_NAME_LENGTH && !name.include?(NAME_SEPARATOR)
  end

  validates :name, presence: true, uniqueness: { scope: :organisation_id }
  validates :organisation, presence: true

  before_save :normalize_name

  def normalize_name
    self.name = self.class.normalize_name(name) if name.present?
  end

  def self.counts_by_type(taggable_type)
    joins(:taggings)
      .where(taggings: { taggable_type: taggable_type })
      .group(:id)
      .order('COUNT(taggings.id) DESC')
      .count
  end
end
