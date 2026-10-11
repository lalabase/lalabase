# frozen_string_literal: true

require 'rails_helper'

# Neo::Users::NameComponent — the render seam for a user's name TEXT
# (doc/user_display_name_avatar_plan.md). Since 05.09.2026 (Slack model) it
# only SPELLS the name; the picture is Neo::Users::AvatarComponent's job and
# the pair comes from viewer_user_chip. Component specs render without an
# authenticated viewer, so the implicit mode goes through the
# viewer_name_display_mode fail-safe and must land on 'full' — that path is
# pinned here on purpose (it is exactly what a broadcast render hits).
RSpec.describe Neo::Users::NameComponent, type: :component do
  let(:user) { build(:user, first_name: 'Guido', last_name: 'Boyke', email: 'guido@example.com') }

  it 'renders the full name without an explicit mode (no viewer => fail-safe default)' do
    render_inline(described_class.new(user: user))

    expect(page).to have_css('span', text: 'Guido Boyke')
  end

  it 'renders the pinned spelling with the full name as hover title' do
    render_inline(described_class.new(user: user, mode: 'first_last_initial'))

    expect(page).to have_css('span[title="Guido Boyke"]', text: 'Guido B.')
  end

  it 'renders the second abbreviated spelling' do
    render_inline(described_class.new(user: user, mode: 'initial_last'))

    expect(page).to have_css('span[title="Guido Boyke"]', text: 'G. Boyke')
  end

  it "spells the legacy stored 'circle' as the full name (picture stopped being a mode on 05.09.2026)" do
    render_inline(described_class.new(user: user, mode: 'circle'))

    expect(page).to have_css('span', text: 'Guido Boyke')
    expect(page).to have_no_css('span.neo-user-avatar')
  end

  it 'styles the span through text_class' do
    render_inline(described_class.new(user: user, text_class: 'font-semibold extra-class'))

    expect(page).to have_css('span.font-semibold.extra-class', text: 'Guido Boyke')
  end

  it 'renders the unknown-user label for a nil user (deleted actor)' do
    render_inline(described_class.new(user: nil))

    expect(page).to have_css('span', text: I18n.t('views.helpers.application.unknown_user'))
  end

  it 'never draws a picture — that is the avatar chip next door' do
    user_with_avatar = create(:user, first_name: 'Guido', last_name: 'Boyke').tap do |u|
      u.avatar.attach(io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
                      filename: 'avatar.png', content_type: 'image/png')
      u.save!
    end

    render_inline(described_class.new(user: user_with_avatar))

    expect(page).to have_no_css('img')
    expect(page).to have_text('Guido Boyke')
  end
end
