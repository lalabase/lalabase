# frozen_string_literal: true

require 'rails_helper'

# The core has no legal pages of its own: what an imprint must say depends on
# who runs the instance and where. An operator with a website links it. An
# operator without one -- an internal team tool is the normal case -- writes the
# text in the admin area, and the instance serves it here.
#
# Our own cloud sets the URLs and leaves the texts empty, so none of this
# changes anything there (website split, W6).
RSpec.describe 'The legal pages of an instance', type: :request do
  describe 'with nothing configured' do
    it 'has no page behind the address', legal_identity: {} do
      get instance_legal_page_path(:imprint)

      expect(response).to have_http_status(:not_found)
    end

    it 'shows no link on the sign-in page', legal_identity: {} do
      get new_user_session_path

      expect(response.body).not_to include(instance_legal_page_path(:imprint))
      expect(response.body).not_to include(I18n.t('views.shared.legal.imprint'))
    end
  end

  describe 'with a text written in the admin area' do
    let(:configured) { { imprint_body: "## Betreiber\n\nMusterfirma GmbH, Musterstadt" } }

    it 'serves it under its own address' do
      with_legal_identity(**configured) do
        get instance_legal_page_path(:imprint)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Musterfirma GmbH')
        # Markdown, not the raw source.
        expect(response.body).to include('<h2>Betreiber</h2>')
      end
    end

    it 'is linked from the sign-in page' do
      with_legal_identity(**configured) do
        get new_user_session_path

        expect(response.body).to include(instance_legal_page_path(:imprint))
      end
    end

    # An admin pastes this and the page is public. The markdown helper sanitises,
    # and that is load-bearing rather than incidental.
    it 'does not run what somebody pasted into it' do
      with_legal_identity(imprint_body: "Hallo <script>alert('x')</script> Welt") do
        get instance_legal_page_path(:imprint)

        expect(response.body).to include('Hallo')
        expect(response.body).not_to include('<script>')
        expect(response.body).not_to include("alert('x')")
      end
    end

    it 'leaves the pages the operator did not write alone' do
      with_legal_identity(**configured) do
        get instance_legal_page_path(:privacy)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # Two copies of a privacy policy is how they start to differ.
  describe 'with both an address and a text' do
    it 'links the address and not the page in this instance' do
      with_legal_identity(imprint_page_url: 'https://operator.example/impressum',
                          imprint_body: 'Sollte nicht verlinkt werden') do
        get new_user_session_path

        expect(response.body).to include('https://operator.example/impressum')
        expect(response.body).not_to include(instance_legal_page_path(:imprint))
      end
    end
  end

  # The route constrains :page to the three keys, so anything else is not this
  # controller answering 'no' -- it never reaches it.
  it 'has no address beyond the three pages' do
    get '/legal/anything'

    expect(response).to have_http_status(:not_found)
  end
end
