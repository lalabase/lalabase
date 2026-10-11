# frozen_string_literal: true

# Server-side rule for images inside a rich text, included by every carrier of a
# `has_rich_text :content` (Ticket, Post, Note; the static guard in
# spec/models/action_text/rich_text_embed_guard_inclusion_spec.rb enforces that).
# Spike plan doc/inline_bilder_spike_plan.md, E1 and decisions D2, D5, D6, D9, D10.
#
#   content assigned ──before_validation──▶ strip url/href from every attachment node (D9)
#                     ──validate──────────▶ DELTA only (D10):
#                        new blob  (not yet attached to this text)   ─▶ identify, type, size, file, organisation
#                        new dead sgid (not in the previous body)    ─▶ refuse
#                        everything that was already in the text      ─▶ untouched
#                     ──after_commit──────▶ warm the display variant of each new blob (D8)
#
# Why a concern on the carrier and not a validator on ActionText::RichText: has_rich_text
# attaches the text with autosave: true, so errors of the RichText would reach the carrier
# as NestedError under `rich_text_content.body`, never under :content, and the forms show
# errors per field name (D2). Why delta and not "every blob in the text": the four
# production tickets with a PDF tile (S7) must stay editable, the type identification
# (a chunk download) is paid only for new blobs, and a draft whose image was purged gets
# a 422 with a message instead of a silently stored placeholder (D10).
module RichTextEmbedGuard
  extend ActiveSupport::Concern

  # Attributes Trix and Lexxy write into the attachment node at upload time. `url` carries
  # a signed_id WITHOUT expiry (the 15-minute limit applies only to links generated at
  # render time), so a stored node would be a permanent, login-free link. Both editors
  # render a node without url through the attachment partial, with a fresh link.
  STRIPPED_ATTACHMENT_ATTRIBUTES = %w[url href].freeze

  # Lexxy writes a node that carries no url back as `sgid` plus a `content` attribute
  # holding the RENDERED partial (the <figure> with a 15-minute representation link).
  # ActionText ignores `content` whenever the sgid resolves (ContentAttachment only accepts
  # html content types) and renders from the blob, so on a blob node the attribute is dead
  # weight with an expiring link inside. Removed for blob nodes only: wiki mentions keep
  # their `content` (the serializer falls back to it for a deleted target).
  BLOB_NODE_REDUNDANT_ATTRIBUTES = %w[content].freeze

  included do
    before_validation :strip_rich_text_embed_urls, if: :rich_text_content_changing?
    # prepend: since Rails 8.1 the rich text collects its embeds in ITS OWN before_validation,
    # which runs inside the autosave validation that has_rich_text registers ahead of this
    # concern. A blob without a file would raise FileNotFoundError there, in identify, before
    # this guard could refuse it. So the guard runs first (the delta itself no longer depends
    # on the order, see persisted_embed_blob_ids).
    validate :rich_text_embeds_acceptable, if: :rich_text_content_changing?, prepend: true
    before_save :strip_rich_text_blob_node_content, if: :rich_text_content_changing?
    after_commit :warm_new_rich_text_embed_variants
  end

  private

  # Answered from memory, never from the database: `content` would LOAD the rich text for
  # every save of a carrier whose text nobody touched (a status change, a bulk update), one
  # query per record. A rich text that was never touched in this instance cannot have been
  # changed here, so the guard has nothing to do. `association_cached?` and not
  # `association(...)`: the latter INSTANTIATES the association, and Rails' own autosave
  # validation then reloads every instantiated has_one, which is the same query again.
  def rich_text_content_changing?
    return false unless association_cached?(:rich_text_content)

    rich_text = association(:rich_text_content).target
    return false unless rich_text

    rich_text.body.present? && (rich_text.new_record? || rich_text.changed?)
  end

  def strip_rich_text_embed_urls
    fragment = content.body&.fragment
    return if fragment.blank?

    nodes = fragment.find_all(ActionText::Attachment.tag_name)
    return if nodes.none? { |node| STRIPPED_ATTACHMENT_ATTRIBUTES.any? { |attr| node.has_attribute?(attr) } }

    content.body = fragment.replace(ActionText::Attachment.tag_name) do |node|
      STRIPPED_ATTACHMENT_ATTRIBUTES.each { |attr| node.remove_attribute(attr) }
      node
    end.to_html
  end

  def strip_rich_text_blob_node_content
    body = content.body
    return if body.blank?
    return unless body.fragment.find_all(ActionText::Attachment.tag_name).any? { |n| n.has_attribute?('content') }

    blob_sgids = body.attachments.select { |a| a.attachable.is_a?(ActiveStorage::Blob) }.map { |a| a.node['sgid'] }
    return if blob_sgids.empty?

    content.body = body.fragment.replace(ActionText::Attachment.tag_name) do |node|
      BLOB_NODE_REDUNDANT_ATTRIBUTES.each { |attr| node.remove_attribute(attr) } if blob_sgids.include?(node['sgid'])
      node
    end.to_html
  end

  def rich_text_embeds_acceptable
    @new_rich_text_embed_blob_ids = []
    body = content.body
    return if body.blank?

    previous_blob_ids = persisted_embed_blob_ids
    previous_sgids = attachment_sgids_of(content.body_was)
    new_blobs = []

    body.attachments.uniq { |attachment| attachment_identity(attachment) }.each do |attachment|
      attachable = attachment.attachable
      if attachable.is_a?(ActiveStorage::Blob)
        new_blobs << attachable unless previous_blob_ids.include?(attachable.id)
      elsif attachable.is_a?(ActionText::Attachables::MissingAttachable)
        errors.add(:content, :embed_missing) unless previous_sgids.include?(attachment.node['sgid'])
      end
    end
    return if new_blobs.empty?

    references = embed_references_for(new_blobs)
    new_blobs.each do |blob|
      validate_new_embed_blob(blob, references.fetch(blob.id, []))
      @new_rich_text_embed_blob_ids << blob.id
    end

    # A missing file must stop the chain here: the rich text's own validation, next in
    # line, would identify the blob and raise FileNotFoundError, a 500 instead of this
    # error. The carrier's other validations are skipped in that rare state.
    throw :abort if errors.of_kind?(:content, :embed_file_missing)
  end

  # The blobs of the SAVED text, from the database. Since Rails 8.1 every validation of the
  # rich text reassigns content.embeds in memory, so after a first valid? (or a refused save)
  # the association already lists the blobs this guard refused, and a second validation
  # would wave them through as old.
  def persisted_embed_blob_ids
    return [] if content.new_record?

    ActiveStorage::Attachment.where(record: content, name: 'embeds').pluck(:blob_id)
  end

  # One query for the attachments of ALL new blobs and one batched carrier resolution,
  # instead of blob.attachments plus a carrier hop per blob (Prosopite-guarded).
  # @return [Hash{blob_id => [[attachment, carrier], ...]}]
  def embed_references_for(blobs)
    attachments = ActiveStorage::Attachment.where(blob_id: blobs.map(&:id)).includes(:record).to_a
    carriers = AttachmentDeletionRecorder.carriers_of(attachments)
    attachments.group_by(&:blob_id).transform_values { |list| list.map { |a| [a, carriers[a]] } }
  end

  def attachment_identity(attachment)
    attachable = attachment.attachable
    attachable.is_a?(ActiveStorage::Blob) ? [:blob, attachable.id] : [:node, attachment.node['sgid']]
  end

  def attachment_sgids_of(body)
    return [] if body.blank?

    body.fragment.find_all(ActionText::Attachment.tag_name).filter_map { |node| node['sgid'] }
  end

  def validate_new_embed_blob(blob, references)
    unless embed_file_present?(blob)
      errors.add(:content, :embed_file_missing, filename: blob.filename.to_s)
      return
    end

    # Direct-upload blobs carry the CLIENT's content_type until Rails identifies them on
    # attach (in before_save, after validation). Identify here, from the bytes, so a PDF
    # declared as image/png is judged as a PDF.
    blob.identify_without_saving unless blob.identified?

    name = blob.filename.to_s
    errors.add(:content, :embed_not_an_image, filename: name) unless embed_image?(blob)
    errors.add(:content, :embed_too_large, filename: name, max: RichTextEmbeds.max_megabytes) if embed_oversized?(blob)
    errors.add(:content, :embed_foreign_organisation, filename: name) unless embed_blob_within_organisation?(references)
  end

  def embed_image?(blob) = RichTextEmbeds::IMAGE_CONTENT_TYPES.include?(blob.content_type)
  def embed_oversized?(blob) = blob.byte_size > RichTextEmbeds::MAX_BYTE_SIZE

  # The state an aborted direct upload leaves behind: blob row present, no file. Reading
  # the first chunk later (identify) would raise FileNotFoundError inside before_save, a
  # 500 on save; refuse it here with a message instead (E5, third state).
  def embed_file_present?(blob)
    blob.service.exist?(blob.key)
  rescue StandardError
    false
  end

  # Third rule of E1 (D6): a blob is acceptable when nothing references it yet, or when
  # every carrier that references it belongs to THIS organisation. A carrier without an
  # organisation (avatar, user data export) and a reference whose carrier is already
  # gone both count as foreign; copying an image across organisations would otherwise
  # share one blob between two tenants, with one deletion-register entry and one purge
  # for both.
  def embed_blob_within_organisation?(references)
    return true if references.empty?

    references.all? do |(_attachment, carrier)|
      organisation = AttachmentDeletionRecorder.organisation_of(carrier)
      organisation.present? && organisation == self.organisation
    end
  end

  def warm_new_rich_text_embed_variants
    ids = @new_rich_text_embed_blob_ids
    @new_rich_text_embed_blob_ids = nil
    return if ids.blank?

    ids.each { |blob_id| RichTextEmbedVariantJob.perform_later(blob_id) }
  end
end
