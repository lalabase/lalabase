# frozen_string_literal: true

# A merge on the people list above the organisations (GET /people): one person's own
# note that rows of different organisations are the same human.
#
# * No name and no field. What a merged person is called and how to reach them is read
#   from the rows of the organisations, each under its own tenant and with the owner's
#   right there (People::AcrossOrganisations). A group stores no personal data.
# * No tenant: a group reaches over organisations and belongs to its owner alone. An
#   organisation never learns of it. Only the files of the people above the
#   organisations name this model (spec/architecture/people_above_organisations_guard_spec.rb).
# * No tracking: an activity would tell an organisation that somebody knows its person
#   elsewhere.
# * Written by Actors::MergePeople and Actors::SplitPerson only. A group left with fewer
#   than two entries (a row, an organisation or an entry went) is ignored by the read
#   and deleted by the next of those writes.
class PersonGroup < ApplicationRecord
  belongs_to :owner, class_name: 'User'
  # The foreign key takes the entries along as well (ON DELETE CASCADE), for a group
  # that is deleted by a statement.
  has_many :entries, class_name: 'PersonGroupEntry', inverse_of: :person_group, dependent: :delete_all

  scope :owned_by, ->(user) { where(owner_id: user.id) }
  # Groups that join nothing any more.
  scope :leftover, lambda {
    where('(SELECT COUNT(*) FROM person_group_entries WHERE person_group_entries.person_group_id = person_groups.id) < 2')
  }

  # One write at a time per owner (Actors::MergePeople, Actors::SplitPerson, and the move
  # of entries when a member the owner merged twice leaves, PersonGroupEntry.follow_to_row):
  # held until the transaction ends, so the second write reads what the first one stored.
  # owner: the account or its id. The key is a bind; SELECT 1 FROM because the function
  # returns void.
  def self.lock_for(owner)
    connection.select_value(
      "SELECT 1 FROM pg_advisory_xact_lock(hashtextextended('person_groups:' || $1, 0))",
      'PersonGroup owner lock', [(owner.respond_to?(:id) ? owner.id : owner).to_s]
    )
  end
end
