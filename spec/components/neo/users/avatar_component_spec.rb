# frozen_string_literal: true

require 'rails_helper'

# Neo::Users::AvatarComponent — the chip that PICTURES a user.
#
# Split out of NameComponent on 05.09.2026 so a spot can show the picture AND
# the name (the ticket timeline's comment head). The chip markup has one owner:
# NameComponent's circle mode renders through this component, so the examples
# here cover both call paths.
RSpec.describe Neo::Users::AvatarComponent, type: :component do
  let(:user) { build(:user, first_name: 'Guido', last_name: 'Boyke', email: 'guido@example.com') }

  it 'renders the initials with the full name as hover title' do
    render_inline(described_class.new(user: user))

    expect(page).to have_css('span.neo-user-avatar[title="Guido Boyke"]', text: 'GB')
  end

  # Iterating SIZES rather than naming :small and :medium by hand: drop a size
  # from the map and its example goes red instead of silently falling back to
  # :medium through the fetch default, which is what a caller passing the
  # removed size would get in production — the wrong size, no error.
  # An entry removed from the map removes its example, so the two assertions
  # below are what actually goes red.
  it 'offers the identity scales (xs 20 / small 26 / medium 32 / detail 34)' do
    expect(described_class::SIZES.keys).to contain_exactly(:xs, :small, :medium, :detail)
  end

  it 'gives the two sizes genuinely different classes' do
    expect(described_class::SIZES[:small]).not_to eq(described_class::SIZES[:medium])
  end

  described_class::SIZES.each do |size, classes|
    it "renders the #{size} chip with every class the map declares" do
      render_inline(described_class.new(user: user, size: size))

      expect(page.find('span')[:class]).to include(*classes.split)
    end
  end

  it 'falls back to the medium classes for a size that is not in the map' do
    render_inline(described_class.new(user: user, size: :enormous))

    expect(page.find('span')[:class]).to include(*described_class::SIZES[:medium].split)
  end

  it 'renders a block INSIDE the chip (presence dot seam)' do
    render_inline(described_class.new(user: user)) do
      '<span class="presence-dot"></span>'.html_safe
    end

    expect(page).to have_css('span.neo-user-avatar .presence-dot')
  end

  it 'merges a passed class into the chip' do
    render_inline(described_class.new(user: user, class: 'extra-class'))

    expect(page).to have_css('span.neo-user-avatar.extra-class')
  end

  it 'draws fallback initials for a nil user (system events)' do
    render_inline(described_class.new(user: nil, fallback_initials: 'S'))

    expect(page).to have_css('span.neo-user-avatar', text: 'S')
  end

  # A row whose author is gone must keep its text column where the rows above
  # it are, so the chip stays as an empty circle rather than collapsing to
  # nothing and pulling the whole comment 24px to the left.
  it 'draws an empty chip for a nil user without fallback initials' do
    render_inline(described_class.new(user: nil))

    expect(page).to have_css('span.neo-user-avatar')
    expect(page.find('span').text.strip).to eq('')
  end

  # ONE shape everywhere (user report 05.09.2026: "es werden noch
  # unterschiedliche Bilder angezeigt"): the 5px-corner square won and the
  # temporary shape: option is gone. The corner is pinned HERE and only here;
  # every other spec hangs onto .neo-user-avatar so a future shape change is
  # one example, not a sweep.
  describe 'the one chip shape' do
    it 'is a 5px-corner square, never a circle' do
      render_inline(described_class.new(user: user))

      chip = page.find('span')
      expect(chip[:class]).to include('rounded-[5px]')
      expect(chip[:class]).not_to include('rounded-full')
    end

    it 'gives a picture the same corner' do
      with_picture = create(:user, first_name: 'Guido', last_name: 'Boyke').tap do |u|
        u.avatar.attach(io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
                        filename: 'avatar.png', content_type: 'image/png')
        u.save!
      end

      render_inline(described_class.new(user: with_picture))

      image = page.find('img')
      expect(image[:class]).to include('object-cover', 'rounded-[5px]')
      expect(image[:class]).not_to include('rounded-full')
    end
  end

  describe 'with an uploaded avatar' do
    let(:user_with_avatar) do
      create(:user, first_name: 'Guido', last_name: 'Boyke').tap do |u|
        u.avatar.attach(
          io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )
        u.save!
      end
    end

    it 'renders the thumb variant with hidden initials ready for a broken image' do
      render_inline(described_class.new(user: user_with_avatar))

      expect(page).to have_css('span.neo-user-avatar[title="Guido Boyke"] img')
      expect(page).to have_css('[data-avatar-fallback-target="initials"][hidden]', text: 'GB', visible: :hidden)
      expect(page).to have_css('img[data-action="error->avatar-fallback#showInitials"]')
    end

    # attached? is true for a picture that is only PICKED, not stored — the
    # state a form is in after a failed save. Its blob is a new record, and
    # signed_id raises on those, so the URL must not be built at all. Initials
    # are also the honest preview: nothing is saved yet.
    # The component guards with respond_to?(:avatar) because Admin::User shares
    # the NameDisplay concern but deliberately has NO attachment (user.rb).
    # Take the guard away and every admin-backend render raises NoMethodError.
    it 'renders initials for the admin twin, which has no attachment at all' do
      twin = Admin::User.find(user_with_avatar.id)

      render_inline(described_class.new(user: twin))

      expect(page).to have_no_css('img')
      expect(page).to have_css('span.neo-user-avatar', text: 'GB')
    end

    it 'falls back to initials for a picked but unsaved picture' do
      picked = create(:user, first_name: 'Guido', last_name: 'Boyke')
      # Assignment, not attach: attach() saves a persisted record right away,
      # which is the state this example must NOT be in.
      picked.avatar = {
        io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
        filename: 'pending.png',
        content_type: 'image/png'
      }
      expect(picked.avatar).to be_attached
      expect(picked.avatar.blob).not_to be_persisted

      render_inline(described_class.new(user: picked))

      expect(page).to have_no_css('img')
      expect(page).to have_css('span.neo-user-avatar', text: 'GB')
    end
  end

  # Production, 07.09.2026: the picture URL is signed with an expiry
  # (config.active_storage.urls_expire_in), and that expiry was stamped to the
  # millisecond of the render. Every chip of the SAME picture was therefore a
  # different address, the browser could neither dedupe nor cache them, and a
  # ticket list with one assignee fired 53-59 image requests per load. The
  # Rack::Attack budget (requests/ip, 300 per 5 minutes) then answered the list
  # itself with 429 "Zu viele Anfragen". The expiry is rounded to a slot since:
  # one address per picture and slot, and the link outlives the slot it was
  # rendered in by a whole further slot, so a page built one second before the
  # boundary can still load its pictures.
  describe 'the picture URL within a slot' do
    include ActiveSupport::Testing::TimeHelpers

    let(:slot) { ActiveStorage.urls_expire_in }
    # A slot boundary in epoch arithmetic (the component counts from the epoch,
    # not from the wall clock), computed rather than assumed so a changed slot
    # length keeps these examples honest.
    let(:slot_start) { Time.at((Time.utc(2026, 9, 7, 16).to_i / slot.to_i) * slot.to_i).utc }
    let(:user_with_avatar) do
      create(:user, first_name: 'Guido', last_name: 'Boyke').tap do |u|
        u.avatar.attach(
          io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )
        u.save!
      end
    end

    def picture_src_at(time)
      travel_to(time) do
        render_inline(described_class.new(user: user_with_avatar))
        page.find('img')[:src]
      end
    end

    def signed_blob_id_of(src)
      src[%r{/representations/proxy/([^/]+)/}, 1]
    end

    def link_alive_at?(src, time)
      travel_to(time) { ActiveStorage::Blob.find_signed(signed_blob_id_of(src)).present? }
    end

    it 'is configured with an expiry at all (the slot has a length)' do
      expect(slot).to be_present
    end

    it 'gives two chips of the same picture rendered in one slot the same address' do
      first = picture_src_at(slot_start + 1.second)
      last = picture_src_at(slot_start + slot - 1.second)

      expect(last).to eq(first)
    end

    it 'moves the picture to a new address once the slot boundary passes' do
      before = picture_src_at(slot_start + slot - 1.second)
      after = picture_src_at(slot_start + slot)

      expect(after).not_to eq(before)
    end

    it 'keeps a link rendered one second before the boundary alive through the whole next slot' do
      src = picture_src_at(slot_start + slot - 1.second)

      expect(link_alive_at?(src, slot_start + (2 * slot) - 1.second)).to be(true)
      expect(link_alive_at?(src, slot_start + (2 * slot) + 1.second)).to be(false)
    end

    it 'still lets a leaked link die, within two slots of the render' do
      src = picture_src_at(slot_start)

      expect(link_alive_at?(src, slot_start + (2 * slot) + 1.second)).to be(false)
    end

    it 'falls back to a plain, unexpiring address when no expiry is configured' do
      allow(ActiveStorage).to receive(:urls_expire_in).and_return(nil)

      src = picture_src_at(Time.utc(2026, 9, 7, 16))

      expect(link_alive_at?(src, Time.utc(2036, 9, 7, 16))).to be(true)
    end
  end
end
