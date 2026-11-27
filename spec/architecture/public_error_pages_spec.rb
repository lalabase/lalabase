# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# The four static error pages in public/ (Lalabase::ErrorPages, script/error_pages).
#
# Until 2026-11-27 public/ was ignored as a whole, so none of these files was ever
# deployed: a wrong address on the live instance answered 404 with an empty body,
# and an expired form, a crash and a browser the gate refuses ended the same way.
# This spec holds that the files are there, are in the repository, match their
# template, need nothing but themselves, and are what Rails serves.
RSpec.describe 'Public error pages' do
  pages = Lalabase::ErrorPages::PAGES

  pages.each do |name, key|
    describe "public/#{name}.html" do
      let(:path) { Lalabase::ErrorPages.path(name) }
      let(:html) { File.read(path) }

      it 'is not ignored by git, so a deploy and the image carry it' do
        _out, status = Open3.capture2e('git', 'check-ignore', '-q', path.to_s, chdir: Rails.root.to_s)

        expect(status.exitstatus).to eq(1), "#{name}.html is ignored by .gitignore"
      end

      it 'is what script/error_pages writes from the template and the texts' do
        expect(html).to eq(Lalabase::ErrorPages.render(name)),
                        'public/ differs from the template: run `bin/rails runner script/error_pages`'
      end

      it 'says its code and its text in German and in English' do
        expect(html).to include(">#{name.to_i}<")
        Lalabase::ErrorPages::LOCALES.each do |locale|
          expect(html).to include(ERB::Util.h(I18n.t("error_pages.#{key}.heading", locale: locale)))
          expect(html).to include(%(lang="#{locale}"))
        end
      end

      it 'runs no script and loads nothing from another host' do
        expect(html).not_to match(/<script/i)
        expect(html).not_to match(%r{(?:https?:)?//[a-z0-9]}i)

        references = html.scan(/(?:href|src)="([^"]*)"|url\("([^"]*)"\)/).flatten.compact
        expect(references).to include('/')
        fonts = references - ['/']
        expect(fonts).to all(start_with('/fonts/'))
        fonts.each { |font| expect(Rails.public_path.join(font.delete_prefix('/'))).to exist }
      end
    end
  end

  # Rails' own exceptions app (no exceptions_app is configured) serves these files
  # for an HTML request and its own JSON for a program, as it did before: the
  # files change nothing for the API.
  describe 'what the exceptions app answers' do
    let(:exceptions_app) { ActionDispatch::PublicExceptions.new(Rails.public_path.to_s) }

    def answer(status, accept)
      env = Rack::MockRequest.env_for("/#{status}", 'HTTP_ACCEPT' => accept)
      env['action_dispatch.original_path'] = '/somewhere'
      code, _headers, body = exceptions_app.call(env)
      [code, body.join]
    end

    { 404 => '404', 422 => '422', 500 => '500' }.each do |status, name|
      it "serves public/#{name}.html for an HTML request with #{status}" do
        expect(answer(status, 'text/html')).to eq([status, File.read(Lalabase::ErrorPages.path(name))])
      end
    end

    it 'keeps its JSON body for a program' do
      code, body = answer(500, 'application/json')

      expect(code).to eq(500)
      expect(JSON.parse(body)).to eq('status' => 500, 'error' => 'Internal Server Error')
    end
  end

  describe 'a request that ends in an error', type: :request do
    around do |example|
      # The test environment shows the debug page for a local request; this is the
      # page a visitor of a production instance gets.
      config = Rails.application.env_config
      before = config['action_dispatch.show_detailed_exceptions']
      config['action_dispatch.show_detailed_exceptions'] = false
      example.run
    ensure
      config['action_dispatch.show_detailed_exceptions'] = before
    end

    it 'answers an unknown address with the 404 page' do
      get '/an-address-that-does-not-exist'

      expect(response).to have_http_status(:not_found)
      expect(response.body).to eq(File.read(Lalabase::ErrorPages.path('404')))
    end
  end

  describe 'the browser gate', type: :request do
    it 'answers a browser it refuses with the 406 page' do
      get new_user_session_path,
          headers: { 'User-Agent' => 'Mozilla/5.0 (Windows NT 6.1; Trident/7.0; rv:11.0) like Gecko' }

      expect(response).to have_http_status(:not_acceptable)
      expect(response.body).to eq(File.read(Lalabase::ErrorPages.path('406-unsupported-browser')))
    end
  end
end
