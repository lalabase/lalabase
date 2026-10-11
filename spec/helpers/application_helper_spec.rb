# frozen_string_literal: true

require 'rails_helper'

# What: the people seams of ApplicationHelper: viewer_ordered_users,
#   viewer_user_list and viewer_user_chips.
# Type: helper spec with real users, the viewer stubbed as current_user.
# Why: two rules the user set on 08.09.2026 live in these methods and nowhere
#   else. A group of people shows the name only while it is ONE person (two
#   names never fit an assignee column, two chips do), and the viewer reads
#   themselves first, the rest alphabetically. Each example breaks at the one
#   line that carries its rule.
RSpec.describe ApplicationHelper, type: :helper do
  let(:viewer) { create(:user, first_name: 'Mara', last_name: 'Zinn') }
  let(:anna) { create(:user, first_name: 'Anna', last_name: 'Berg') }
  let(:erika) { create(:user, first_name: 'Erika', last_name: 'Musterfrau') }

  before { allow(helper).to receive(:current_user).and_return(viewer) }

  def chip_titles(html)
    Capybara.string(html).all('span.neo-user-avatar').map { |chip| chip[:title] }
  end

  describe '#viewer_ordered_users' do
    it 'puts the viewer first and the rest by displayed name' do
      expect(helper.viewer_ordered_users([erika, viewer, anna])).to eq([viewer, anna, erika])
    end

    it 'is the alphabetical order alone when the viewer is not among the people' do
      expect(helper.viewer_ordered_users([erika, anna])).to eq([anna, erika])
    end

    it 'sorts by the name as displayed, first name first, like the assignee picker' do
      # By last name Adler would come before Berg; by displayed name Anna comes first.
      zoe = create(:user, first_name: 'Zoe', last_name: 'Adler')
      expect(helper.viewer_ordered_users([zoe, anna])).to eq([anna, zoe])
    end

    it 'ignores case' do
      ben = create(:user, first_name: 'ben', last_name: 'Adler')
      expect(helper.viewer_ordered_users([erika, ben])).to eq([ben, erika])
    end

    it 'keeps two namesakes in one order however they arrive (the id breaks the tie)' do
      twin = create(:user, first_name: 'Anna', last_name: 'Berg')
      expect(helper.viewer_ordered_users([twin, anna])).to eq(helper.viewer_ordered_users([anna, twin]))
    end

    it 'is alphabetical when there is no viewer (broadcast renders, component specs)' do
      allow(helper).to receive(:current_user).and_raise(StandardError, 'no warden')
      expect(helper.viewer_ordered_users([erika, anna])).to eq([anna, erika])
    end

    it 'takes a relation as well as an array' do
      expect(helper.viewer_ordered_users(User.where(id: [erika.id, anna.id]))).to eq([anna, erika])
    end
  end

  describe '#viewer_user_list' do
    it 'renders ONE person as the chip+name pair' do
      html = Capybara.string(helper.viewer_user_list([erika], size: :xs))
      expect(html).to have_css('span.neo-user-avatar[title="Erika Musterfrau"]', text: 'EM')
      expect(html).to have_text('Erika Musterfrau')
    end

    it 'renders SEVERAL people as chips only, the names in the hover titles' do
      html = Capybara.string(helper.viewer_user_list([erika, anna], size: :xs))
      expect(html).to have_css('span.neo-user-avatar[title="Erika Musterfrau"]', text: 'EM')
      expect(html).to have_css('span.neo-user-avatar[title="Anna Berg"]', text: 'AB')
      expect(html).to have_no_text('Erika Musterfrau')
      expect(html).to have_no_text('Anna Berg')
    end

    it 'draws the chips in viewer order' do
      expect(chip_titles(helper.viewer_user_list([erika, viewer, anna]))).to eq(['Mara Zinn', 'Anna Berg', 'Erika Musterfrau'])
    end

    it 'is nil for nobody, so the caller keeps its own empty state' do
      expect(helper.viewer_user_list([])).to be_nil
    end
  end

  describe '#viewer_user_chips' do
    it 'renders chips only, even for one person' do
      html = Capybara.string(helper.viewer_user_chips([erika]))
      expect(html).to have_css('span.neo-user-avatar[title="Erika Musterfrau"]', text: 'EM')
      expect(html).to have_no_text('Erika Musterfrau')
    end

    it 'draws the chips in viewer order' do
      expect(chip_titles(helper.viewer_user_chips([erika, viewer, anna]))).to eq(['Mara Zinn', 'Anna Berg', 'Erika Musterfrau'])
    end

    it 'is nil for nobody' do
      expect(helper.viewer_user_chips([])).to be_nil
    end
  end

  # The three helpers every core page uses for the operator identity. Unset URLs must
  # render nothing, never an empty href, and the consent sentence keeps its words.
  describe 'legal helpers' do
    it 'links a configured page and renders nothing for a missing one',
       legal_identity: { privacy_page_url: 'https://public.example/privacy' } do
      expect(helper.legal_page_link(:privacy, label: 'Datenschutz')).to eq('<a href="https://public.example/privacy">Datenschutz</a>')
      expect(helper.legal_page_link(:terms, label: 'AGB')).to be_nil
      expect(helper.legal_page_link(:terms, label: 'AGB', fallback_to_label: true)).to eq('AGB')
    end

    it 'joins only the configured footer links',
       legal_identity: { imprint_page_url: 'https://public.example/imprint', terms_page_url: 'https://public.example/terms' } do
      html = helper.legal_footer_links(separator: ' | ')

      expect(Nokogiri::HTML.fragment(html).css('a').map { |a| a['href'] })
        .to eq(%w[https://public.example/imprint https://public.example/terms])
      expect(html).to include('</a> | <a')
    end

    it 'returns an empty, blank footer without any URL', legal_identity: {} do
      expect(helper.legal_footer_links(separator: ' | ')).to be_blank
    end

    it 'credits the operator when named, the product otherwise' do
      with_legal_identity(operator_name: 'Configured Operator') do
        expect(helper.legal_operator_credit).to eq("© #{Date.current.year} Configured Operator")
      end
      with_legal_identity { expect(helper.legal_operator_credit).to eq('powered by Lalabase') }
    end
  end
end
