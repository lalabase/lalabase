# frozen_string_literal: true

require 'rails_helper'

# User::NameDisplay — the single owner of name rendering
# (doc/user_display_name_avatar_plan.md, S1). These examples pin the string
# each mode produces, the fallbacks for partial/missing name parts, and the
# backwards compatibility of the no-argument display_name (it replaced the
# historic User#display_name and must stay bit-identical for existing sites).
RSpec.describe User::NameDisplay, type: :model do
  def user_with(first: nil, last: nil, email: 'guido.tester@example.com')
    build(:user, first_name: first, last_name: last, email: email)
  end

  describe '#display_name' do
    context 'with both name parts' do
      let(:user) { user_with(first: 'Guido', last: 'Boyke') }

      it "renders the full name by default (mode 'full')" do
        expect(user.display_name).to eq('Guido Boyke')
        expect(user.display_name(mode: 'full')).to eq('Guido Boyke')
      end

      it "abbreviates the last name in 'first_last_initial'" do
        expect(user.display_name(mode: 'first_last_initial')).to eq('Guido B.')
      end

      it "abbreviates the first name in 'initial_last'" do
        expect(user.display_name(mode: 'initial_last')).to eq('G. Boyke')
      end

      it "renders 'circle' as the full name (a circle has no text form)" do
        expect(user.display_name(mode: 'circle')).to eq('Guido Boyke')
      end

      it 'renders an unknown mode as the full name (stale stored value must never blank a name)' do
        expect(user.display_name(mode: 'evil')).to eq('Guido Boyke')
      end

      it 'accepts symbol modes' do
        expect(user.display_name(mode: :initial_last)).to eq('G. Boyke')
      end

      it 'upcases the initial of a lowercased name part' do
        expect(user_with(first: 'guido', last: 'boyke').display_name(mode: 'initial_last')).to eq('G. boyke')
      end
    end

    context 'with a single name part (abbreviation needs BOTH parts)' do
      it 'renders only the first name in every mode' do
        user = user_with(first: 'Guido')
        expect(user.display_name(mode: 'first_last_initial')).to eq('Guido')
        expect(user.display_name(mode: 'initial_last')).to eq('Guido')
      end

      it 'renders only the last name in every mode' do
        user = user_with(last: 'Boyke')
        expect(user.display_name(mode: 'first_last_initial')).to eq('Boyke')
        expect(user.display_name(mode: 'initial_last')).to eq('Boyke')
      end
    end

    context 'without any name part' do
      it 'falls back to the email local part (historic display_name contract)' do
        expect(user_with.display_name).to eq('guido.tester')
        expect(user_with.display_name(mode: 'first_last_initial')).to eq('guido.tester')
      end
    end

    it 'strips stray whitespace from stored name parts' do
      expect(user_with(first: ' Guido ', last: nil).display_name).to eq('Guido')
      expect(user_with(first: ' Guido ', last: ' Boyke ').display_name(mode: 'first_last_initial')).to eq('Guido B.')
    end
  end

  describe '#initials' do
    it 'takes the first letters of both name parts, upcased' do
      expect(user_with(first: 'guido', last: 'boyke').initials).to eq('GB')
    end

    it 'takes first and last word of a multi-word single name part' do
      expect(user_with(first: 'Guido Max Boyke').initials).to eq('GB')
    end

    it 'takes the first two characters of a one-word name' do
      expect(user_with(first: 'Guido').initials).to eq('GU')
    end

    it 'falls back to the email local part' do
      expect(user_with.initials).to eq('GU')
    end

    it 'survives a one-character email local part' do
      expect(user_with(email: 'g@example.com').initials).to eq('G')
    end
  end

  describe '#full_name' do
    it 'stays the raw unstripped pair (long-standing public API)' do
      expect(user_with(first: 'Guido', last: nil).full_name).to eq('Guido ')
    end
  end
end
