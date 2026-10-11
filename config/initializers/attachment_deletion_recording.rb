# frozen_string_literal: true

# config/initializers/attachment_deletion_recording.rb
#
# Hooks the deletion register (AVV § 12 Abs. 7) into ActiveStorage::Attachment.
#
# WHY HERE AND NOWHERE ELSE. There is no central deletion path for attachments.
# Five places call purge themselves; the mass runs through Rails' own automatism
# — has_one_attached / has_many_attached install dependent: :purge_later, so
# every destroy of a carrier (TicketDocument, PostDocument, DocumentVersion, …)
# triggers one, as does ActionText and replace_on_assign_to_many. Recording in
# those five call sites would catch the smaller half and would have to be
# repeated by hand in every future deletion path. The attachment row is the one
# place all of them pass through, and the last point at which blob metadata AND
# the carrier still exist — one step later the organisation is no longer
# resolvable.
#
# before_destroy, not after: the record is what makes the organisation
# resolvable, and Rails purges the blob only after the destroy commit.
#
# The hook is deliberately unable to abort the deletion. AttachmentDeletionRecorder
# swallows every error, and no callback here returns throw :abort.
Rails.application.config.to_prepare do
  ActiveStorage::Attachment.class_eval do
    unless method_defined?(:record_deletion_in_register)
      before_destroy :record_deletion_in_register

      def record_deletion_in_register
        AttachmentDeletionRecorder.call(attachment: self)
        # Explicitly not the recorder's return value: a nil result (excluded
        # carrier, not the last reference) must not read as a halted callback.
        true
      end
    end
  end
end
