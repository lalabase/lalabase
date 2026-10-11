# frozen_string_literal: true

require 'rails_helper'

# Every page a signed-out visitor can reach shares one skeleton: brand row,
# paper form column, legal line, dark context panel. Until 20.09.2026 that
# skeleton was hand-copied into each view -- three copies, and the four pages
# rebuilt that day would have made seven. It lives in layouts/application_auth
# now, and this guard holds both halves of that move:
#
#   1. every page still renders it,
#   2. no view builds it again by hand.
#
# The third part is about honesty rather than structure. The panels of the
# password, confirmation and unlock pages state a deadline, and those numbers
# come from the Devise configuration. A typed "6 hours" survives a changed
# setting and lies to the reader; changing the setting here has to change the
# page.
RSpec.describe 'The skeleton of the signed-out pages', :ci_guard, type: :request do
  skeleton_parts = {
    'brand row' => '.lp-auth-top .lp-brand',
    'form column' => '.lp-auth-form-col',
    'legal line' => '.lp-auth-legal',
    'context panel' => '.lp-auth-panel .lp-auth-panel-in'
  }.freeze

  def page
    Nokogiri::HTML(response.body)
  end

  describe 'the layout renders it' do
    # Reachable without a session and without a token that has to exist: the
    # reset token is only written into a hidden field on GET, Devise looks it up
    # on PUT, so any string renders the page.
    pages = {
      'sign-in' => :new_user_session_path,
      'sign-up' => :new_user_registration_path,
      'forgot password' => :new_user_password_path,
      'resend confirmation' => :new_user_confirmation_path,
      'unlock account' => :new_user_unlock_path
    }

    pages.each do |name, helper|
      it "carries every part on the #{name} page" do
        get public_send(helper)

        expect(response).to have_http_status(:ok)
        skeleton_parts.each do |part, selector|
          expect(page.at_css(selector)).to be_present, "#{name} is missing the #{part} (#{selector})"
        end
      end
    end

    it 'carries every part on the new-password page' do
      get edit_user_password_path(reset_password_token: 'probe')

      expect(response).to have_http_status(:ok)
      skeleton_parts.each_value { |selector| expect(page.at_css(selector)).to be_present }
    end
  end

  describe 'no view builds it a second time' do
    it 'keeps the skeleton markup out of app/views/devise' do
      owned_by_the_layout = ['lp-auth-form-col', 'lp-auth-legal', '<aside']
      offenders = Dir[Rails.root.join('app/views/devise/**/*.erb')].flat_map do |path|
        relative = Pathname(path).relative_path_from(Rails.root).to_s
        File.readlines(path).each_with_index.filter_map do |line, index|
          marker = owned_by_the_layout.find { |m| line.include?(m) }
          "#{relative}:#{index + 1}: #{marker}" if marker
        end
      end

      expect(offenders).to be_empty,
                           "These belong to layouts/application_auth, not to a view:\n#{offenders.join("\n")}"
    end
  end

  describe 'the panel states the configuration, not a typed number' do
    def panel_text
      page.css('.lp-auth-callout').text.squish
    end

    it 'follows a changed password reset deadline' do
      get new_user_password_path
      expect(panel_text).to include('6 Stunden')

      allow(Devise).to receive(:reset_password_within).and_return(90.minutes)
      get new_user_password_path

      expect(panel_text).to include('2 Stunden').or include('1 Stunde')
      expect(panel_text).not_to include('6 Stunden')
    end

    it 'follows a changed confirmation grace period' do
      get new_user_confirmation_path
      expect(panel_text).to include('3 Tage').and include('7 Tage')

      allow(Devise).to receive(:allow_unconfirmed_access_for).and_return(1.day)
      get new_user_confirmation_path

      expect(panel_text).to include('einen Tag')
    end

    it 'follows a changed lock threshold' do
      get new_user_unlock_path
      expect(panel_text).to include("#{Devise.maximum_attempts} Fehlversuchen")

      allow(Devise).to receive(:maximum_attempts).and_return(9)
      get new_user_unlock_path

      expect(panel_text).to include('9 Fehlversuchen')
    end

    # :both and :time unlock by themselves, :email does not. The sentence is a
    # promise either way, so it may only appear for the strategies that keep it.
    it 'drops the self-unlock sentence when only the email link unlocks' do
      allow(Devise).to receive(:unlock_strategy).and_return(:email)
      get new_user_unlock_path

      expect(panel_text).to include('Fehlversuchen')
      expect(panel_text).not_to include('von selbst')
    end
  end

  # Until 20.09.2026 the only partial linking to the confirmation and unlock
  # pages (devise/shared/_links) was rendered by nothing, so both were reachable
  # by typing the address -- while app/docs/{de,en}/02-guides/01-basics/
  # 03-confirm-email.md promised the link "on the sign-in page" in both
  # languages. A page nobody can click is not a page.
  describe 'no signed-out page is a dead end' do
    { 'the confirmation page' => :new_user_confirmation_path,
      'the unlock page' => :new_user_unlock_path }.each do |name, helper|
      it "reaches #{name} from the sign-in page" do
        get new_user_session_path

        target = public_send(helper)
        link = page.at_css("a[href='#{target}']")
        expect(link).to be_present, "the sign-in page does not link to #{target}"

        get link['href']
        expect(response).to have_http_status(:ok)
      end
    end
  end

  # The layout floated the flash as a fixed banner across the middle of the
  # screen until 20.09.2026, where on the split screen it covered the dark
  # panel. It sits above the heading in the paper column now.
  describe 'the flash' do
    it 'sits in the form column and announces itself' do
      # No token: Devise sets an alert and sends the visitor to the sign-in page.
      get edit_user_password_path
      follow_redirect!

      box = page.at_css('.lp-auth-flash')
      expect(box).to be_present
      expect(box['class'].split).to include('lp-auth-flash--alert')
      expect(box['role']).to eq('alert')
      expect(box.ancestors('.lp-auth-main')).not_to be_empty
      expect(box['class'].split).not_to include('fixed', 'absolute')
    end
  end

  describe 'the panel is hidden from screen readers only where it is a mock' do
    it 'hides the inbox mock on the sign-in page' do
      get new_user_session_path

      expect(page.at_css('.lp-auth-panel')['aria-hidden']).to eq('true')
    end

    # The deadline in these panels has no second copy in the form column.
    { 'forgot password' => :new_user_password_path,
      'resend confirmation' => :new_user_confirmation_path,
      'unlock account' => :new_user_unlock_path }.each do |name, helper|
      it "leaves the #{name} panel readable" do
        get public_send(helper)

        expect(page.at_css('.lp-auth-panel')['aria-hidden']).to be_nil
      end
    end
  end
end
