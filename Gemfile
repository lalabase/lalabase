# frozen_string_literal: true

source 'https://rubygems.org'

# Core Rails dependencies
gem 'foreman'
gem 'minitest', '~> 5.26'       # Keep Rails' test dependency on the Ruby-4-compatible 5.x line.
gem 'pg', '~> 1.1'              # Use PostgreSQL as the database for Active Record
gem 'pg_search'
gem 'puma', '>= 8.0.2'          # Puma web server for production
gem 'rails', '~> 8.1.4'
gem 'sprockets-rails'           # The original asset pipeline for Rails

# JavaScript & Frontend
gem 'importmap-rails'           # Use JavaScript with ESM import maps
gem 'stimulus-rails'            # Hotwire's modest JavaScript framework
gem 'tailwindcss-rails', '~> 3.3.1'
gem 'turbo-rails'               # Hotwire's SPA-like page accelerator
# gem 'sassc-rails'               # SassC for asset pipeline - temporarily disabled due to build issues
gem 'commonmarker', '~> 2.8'    # GFM-Markdown → HTML (comrak/Rust, GFM-nativ) für den Wiki-Rückweg
gem 'diff-lcs', '~> 1.6'        # Line diff for Wiki note version history (prod: was test-only transitive)
gem 'lexxy', '~> 0.9'           # Lexical-based ActionText editor (Wiki notes only; Trix stays elsewhere)
gem 'redcarpet'
gem 'reverse_markdown'          # HTML → GFM-Markdown für die Wiki markdown_body-Projektion
gem 'rouge'                     # Syntax highlighting for documentation code blocks
# Pinned to the 3.x line on 27.08.2026: GHSA-7f3r-gwc9-2995 and GHSA-hg3h-g7xc-f7vp are
# fixed in 3.25.0 as well as in 4.9.0, and without a constraint bundle update would take
# the 4.x major across every component in app/components. Lifting this pin is its own job.
gem 'view_component', '~> 3.25'

gem 'dotenv-rails' # Loads environment variables from .env
gem 'pagy', '~> 9.0'
# gem 'hiredis'

# JSON APIs
gem 'jbuilder' # Build JSON APIs with ease

# The locked Linux binary excludes Ruby 4; compile the compatible source gem.
gem 'ffi', require: false, force_ruby_platform: true

# Miscellaneous
gem 'csv' # CSV exports; no longer a default gem in Ruby 3.4
gem 'ostruct' # Admin activity presenters; no longer a default gem in Ruby 4.0
gem 'RedCloth', '~> 4.3' # Textile-to-HTML conversion library
# gem 'tzinfo-data', platforms: %i[windows jruby mswin mingw] # Time zone data for Windows

# Performance
gem 'bootsnap', require: false # Speeds up boot times through caching

# User authentication
gem 'devise', '~> 5.0.4' # Flexible authentication solution for Rails

# Billing master data (doc/billing_stammdaten_plan.md §6)
gem 'countries' # ISO-3166 countries + subdivisions; feeds Accounts::BillingRules
# VAT-ID check, OFFLINE only (E4): #valid_checksum? is pure syntax plus check
# digit and issues no HTTP. The online VIES lookup (#exists?) stays unused on
# purpose -- Stripe verifies authoritatively and reports back by webhook, and a
# VIES outage must never block a form submit.
gem 'valvat'

# File processing
gem 'rubyzip', '~> 3.4' # ZIP file handling; >= 3.4.0 closes CVE-2026-85396 (path traversal in Entry#extract)

# Development and test groups
group :development, :test do
  # gem 'debug', platforms: %i[mri windows], require: 'debug/prelude' # Debugging tool
  gem 'brakeman', require: false # Static analysis security scanner

  gem 'letter_opener' # Display emails in the browser
  gem 'pg_query' # SQL query normalization (required by prosopite with PostgreSQL)
  # Keep pg_query's dependency in this group and avoid its Ruby-incompatible Linux binary.
  gem 'google-protobuf', require: false, force_ruby_platform: true
  gem 'prosopite' # N+1 query detection
  gem 'rails-controller-testing'
  gem 'rubocop-rails-omakase', require: false # Omakase Ruby/Rails style guide
end

group :development do
  gem 'erb_lint', require: false # ERB template linting
  gem 'guard'
  gem 'guard-rspec', require: false
  gem 'i18n-tasks'
  gem 'rubocop', require: false # Ruby static code analyzer and formatter
  gem 'web-console' # Use console on exceptions pages
end

group :test do
  gem 'capybara', '~> 3.40' # System testing framework
  gem 'database_cleaner-active_record', '~> 2.1' # Clean database between tests
  gem 'factory_bot_rails', '~> 6.4.3' # Optional, for factories
  gem 'faker', '~> 3.4' # Faker for generating test data
  gem 'rspec-rails', '~> 7.1.1'
  gem 'selenium-webdriver' # WebDriver for Capybara
  gem 'shoulda-matchers'
  gem 'simplecov', require: false # Test coverage reports
end

# Additional tools
gem 'acts_as_tenant', '~> 1.0'  # Multi-tenancy support for Rails
gem 'annotaterb'
gem 'anthropic', '~> 1.13'      # Anthropic Claude API wrapper (official)
gem 'googleauth', '~> 1.11'     # Service-account OAuth2 token mint for Vertex AI (pure Ruby, no google-cloud SDK)
gem 'mcp', '~> 0.22'            # Official Model Context Protocol SDK (MCP server, Claude Code -> Lalabase)
gem 'parser', '~> 3.3'          # Ruby AST parser (M6 — Layer-1 code symbol extraction)
gem 'pry-rails'                 # Enhanced Rails console with Pry
gem 'ruby-openai', '~> 7.1'     # OpenAI API wrapper
gem 'ruby_tree_sitter', '~> 2.1' # TypeScript/JS AST parser (M10 — Layer-1). Precompiled multi-platform runtime; grammar (.so/.dylib) built from vendored C sources.

# Text extraction
gem 'docx', '~> 0.13.0' # For text extraction from .docx files; 0.10.1+ accepts rubyzip 3
gem 'neighbor'
gem 'pdf-reader', '~> 2.12.0' # For PDF text extraction
gem 'rtf', '~> 0.3.3' # For RTF file support, if desired

gem 'image_processing', '~> 1.2' # active storage & active text
gem 'mini_magick' # image processing, shrinking images
gem 'mission_control-jobs' # Job queue monitoring interface for Solid Queue
gem 'pundit', '~> 2.3'
gem 'pundit-matchers', '~> 4.0', groups: %i[development test]
gem 'rack-attack', '~> 6.7' # Rate limiting and request throttling
gem 'redis', '~> 5.3' # Cache store (staging/production); no longer a job backend
gem 'solid_queue', '~> 1.0' # The only job backend (Rails 8 native)
gem 'whatlanguage'
