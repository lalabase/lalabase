# frozen_string_literal: true

require 'rails_helper'

# Profile picture rules (doc/user_display_name_avatar_plan.md, S2). The
# whitelist lives in ONE owner (UserAvatar); these examples pin that the
# validation actually reads it, that the thumb variant is pre-warmed, and that
# the remove_avatar checkbox seam purges.
RSpec.describe 'User avatar', type: :model do
  let(:user) { create(:user) }

  # identify: false pins the declared content type — with identification on,
  # Marcel would sniff the PNG magic bytes and silently "heal" a wrong type,
  # which is exactly what the rejection example must not let happen.
  def attach_avatar(record, content_type: 'image/png')
    record.avatar.attach(
      io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
      filename: 'avatar.png',
      content_type: content_type,
      identify: false
    )
  end

  before { ActiveJob::Base.queue_adapter = :test }

  describe 'validation' do
    it 'accepts a small PNG' do
      attach_avatar(user)

      expect(user).to be_valid
      expect(user.save).to be true
      expect(user.reload.avatar).to be_attached
    end

    it 'rejects a content type outside the whitelist' do
      # GIF is allowed for rich-text embeds but NOT for avatars — the two
      # lists are different owners on purpose (RichTextEmbeds vs UserAvatar).
      attach_avatar(user, content_type: 'image/gif')

      expect(user).not_to be_valid
      expect(user.errors[:avatar]).to be_present
    end

    it 'rejects a file over the size limit (boundary: limit itself passes)' do
      attach_avatar(user)
      allow(user.avatar.blob).to receive(:byte_size).and_return(UserAvatar::MAX_BYTE_SIZE)
      expect(user).to be_valid

      allow(user.avatar.blob).to receive(:byte_size).and_return(UserAvatar::MAX_BYTE_SIZE + 1)
      expect(user).not_to be_valid
      expect(user.errors[:avatar].join).to include("#{UserAvatar.max_megabytes} MB")
    end

    it 'leaves a user without an avatar untouched' do
      expect(user).to be_valid
    end
  end

  # Iterating the CONSTANT, not a hand-copied list: shrink CONTENT_TYPES to
  # %w[image/png] and the JPEG and WebP examples go red. A negative-only suite
  # would stay green while two of the three advertised formats quietly stopped
  # working — the form's accept attribute and the hint text read the same
  # constant, so nothing else would complain either.
  describe 'the whitelist is read, not hardcoded' do
    # The iteration below would QUIETLY SHRINK with the constant — a deleted
    # entry deletes its example instead of failing it. This assertion is the
    # part that goes red. It is a change detector on purpose: the list is a
    # product decision (04.09.2026) that is repeated in the profile hint text
    # and in the help pages in both languages, so changing it is never a
    # one-line change.
    it 'advertises exactly the three formats the product promised' do
      expect(UserAvatar::CONTENT_TYPES).to contain_exactly('image/png', 'image/jpeg', 'image/webp')
    end

    UserAvatar::CONTENT_TYPES.each do |allowed|
      it "accepts #{allowed}" do
        attach_avatar(user, content_type: allowed)

        expect(user.errors[:avatar]).to be_empty
        expect(user).to be_valid
      end
    end

    # image/gif belongs to RichTextEmbeds, not here; image/svg+xml is the one
    # that would turn a profile picture into script; image/PNG is the casing
    # drift an include? check does not forgive.
    ['image/gif', 'image/svg+xml', 'image/bmp', 'application/pdf', 'text/html', 'image/PNG'].each do |rejected|
      it "rejects #{rejected}" do
        attach_avatar(user, content_type: rejected)

        expect(user).not_to be_valid
        expect(user.errors[:avatar]).to include(I18n.t('activerecord.errors.models.user.attributes.avatar.invalid_content_type'))
      end
    end

    # An accepted type that Active Storage cannot build a variant for renders
    # as initials forever: NameComponent#avatar_image asks representable? and
    # silently gives up. Adding image/heic to the list would be exactly that
    # kind of invisible dead end (see
    # spec/config/active_storage_variable_content_types_spec.rb, which strips
    # BMP/ICO/PSD from the effective list).
    it 'accepts only types Active Storage can actually build a variant for' do
      expect(UserAvatar::CONTENT_TYPES - ActiveStorage.variable_content_types).to be_empty
    end
  end

  # Defense in depth. The examples above pass identify: false to pin the
  # validation layer in isolation; this one leaves identification ON, which is
  # what a real upload gets. The declared type is attacker-controlled — it is
  # a form field — so the rule only holds because Rails re-derives the type
  # from the bytes before the validation ever looks.
  describe 'content type identification (defense in depth)' do
    it 'rejects a BMP that declares itself a PNG' do
      user.avatar.attach(
        io: Rails.root.join('spec/fixtures/files/test_image.bmp').open,
        filename: 'looks_like.png',
        content_type: 'image/png'
      )

      expect(user.avatar.blob.content_type).to eq('image/bmp')
      expect(user).not_to be_valid
      expect(user.errors[:avatar]).to be_present
    end
  end

  describe 'thumb variant pre-warming' do
    let(:thumb) { User.attachment_reflections['avatar'].named_variants[:thumb] }

    it 'enqueues the transform job on attach (no viewer pays the vips run)' do
      expect do
        attach_avatar(user)
        user.save!
      end.to have_enqueued_job(ActiveStorage::TransformJob)
    end

    # The declaration is a contract, and it is the reason UserAvatar owns the
    # number at all. resize_to_limit instead of resize_to_fill would leave
    # non-square pictures letterboxed inside the circle; a changed size would
    # be blurry on retina. Both are silent in every other example here.
    it 'resizes to fill exactly the owner constant' do
      expect(thumb.transformations).to eq(resize_to_fill: UserAvatar::THUMB_SIZE)
    end

    it 'is declared preprocessed, so the variant exists before the first viewer' do
      expect(thumb.preprocessed?(user)).to be(true)
    end
  end

  # dependent: :purge_later is the has_one_attached default and user.rb leans
  # on it in a comment ("dependent purge covers a hard DELETE"). Nothing else
  # in the suite would notice `dependent: false`, and the cost of missing it is
  # a face left in object storage after the account is gone.
  describe 'hard delete (the dependent purge the soft paths cannot use)' do
    it 'drops the attachment row and enqueues the blob purge' do
      attach_avatar(user)
      user.save!
      rows = ActiveStorage::Attachment.where(record_type: 'User', record_id: user.id, name: 'avatar')
      expect(rows.count).to eq(1)

      # with_tenant: destroying a user walks its tenant-scoped associations,
      # unrelated to the avatar but a hard blocker for the delete itself.
      expect do
        ActsAsTenant.with_tenant(create(:organisation)) { user.destroy! }
      end.to have_enqueued_job(ActiveStorage::PurgeJob)

      expect(rows.count).to eq(0)
    end
  end

  # The whole S2 design rests on this: the attachment lives on ::User ONLY, so
  # the polymorphic record_type is "User" no matter which twin saved it, and
  # PersonalDataErasure#erase_avatar! can query that literal from both classes.
  # Move the declaration into the shared NameDisplay concern (the obvious
  # "cleanup") and Admin::User would write record_type "Admin::User": those
  # blobs would never be found again, and the GDPR erasure would silently walk
  # past them. The admin twin parity guard checks CONCERNS, not attachments, so
  # nothing else covers this.
  describe 'the admin twin deliberately carries no attachment' do
    it 'declares no avatar on Admin::User' do
      expect(Admin::User.attachment_reflections.keys).not_to include('avatar')
      expect(Admin::User.new).not_to respond_to(:avatar)
    end

    it 'stores blobs under record_type "User", the literal erase_avatar! queries' do
      attach_avatar(user)
      user.save!

      expect(ActiveStorage::Attachment.where(name: 'avatar', record_id: user.id).pick(:record_type))
        .to eq('User')
    end
  end

  describe '#remove_avatar (profile form checkbox seam)' do
    before do
      attach_avatar(user)
      user.save!
    end

    it "purges the avatar after save when set to '1'" do
      expect { user.update!(remove_avatar: '1') }
        .to have_enqueued_job(ActiveStorage::PurgeJob)
    end

    it "does nothing when set to '0' (unchecked checkbox)" do
      expect { user.update!(remove_avatar: '0') }
        .not_to have_enqueued_job(ActiveStorage::PurgeJob)
    end

    it 'a new upload in the same submit wins over a stale remove checkbox' do
      # Both set at once: the user picked a replacement AND left the checkbox
      # ticked. Purging would answer "replace my picture" with no picture.
      user.update!(
        remove_avatar: '1',
        avatar: {
          io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
          filename: 'replacement.png', content_type: 'image/png'
        }
      )

      expect(user.reload.avatar).to be_attached
      expect(user.avatar.filename.to_s).to eq('replacement.png')
    end
  end
end
