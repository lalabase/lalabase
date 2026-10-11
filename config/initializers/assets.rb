# config/initializers/assets.rb

# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = '1.0'
Rails.application.config.assets.precompile += %w[stimulus-loading.js]

# config/initializers/assets.rb
# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path

# Precompile additional assets.
# application.js, application.css, and all non-JS/CSS in the app/assets
# folder are already added.
# Rails.application.config.assets.precompile += %w[ admin.js admin.css ]

Rails.application.config.assets.paths << Rails.root.join('node_modules')

# CRITICAL: Ensure app/javascript is in asset paths for controller resolution
Rails.application.config.assets.paths << Rails.root.join('app/javascript')

# CSS entry points for precompilation. layout.css, slim_select_overrides.css etc.
# need NO separate entry — they are bundled via *= require in application.css.
Rails.application.config.assets.precompile += %w[
  application.css
  lalabase-fonts.css
  style_guide.css
]

# Lexxy editor JS — gem-provided asset referenced by the importmap pin. Unlike the
# vendored JavaScript (caught by manifest.js link_tree), this lives on the gem's asset
# path, so it must be listed explicitly or asset_path raises NotPrecompiled in production.
# The CSS (lexxy-variables/-content/-editor) needs no entry — bundled via *= require in
# application.css.
Rails.application.config.assets.precompile += %w[lexxy.js]

# Base Stimulus files (still needed for direct inclusion)
Rails.application.config.assets.precompile += %w[
  stimulus.min.js
  stimulus-loading.js
]

# CRITICAL FIX: Ensure ALL controllers are in manifest (double safety)
Rails.application.config.assets.precompile += %w[
  controllers/*.js
  controllers/**/*.js
]

# NOTE: Controllers are compiled via both manifest.js AND explicit globs
# This double approach ensures 100% coverage for all controller patterns

# Bootstrap Icons fonts are NOT pipeline assets: the CSS points at /fonts/, which is
# served straight from public/fonts (filled by bin/copy-fonts / npm run copy:fonts).
