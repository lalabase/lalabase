# frozen_string_literal: true

# Runs on every fresh database (`bin/rails db:prepare` seeds a database it creates)
# and on `bin/rails db:seed`. It never deletes anything and holds no personal data
# (guard: spec/architecture/seeds_guard_spec.rb).
#
# The first instance admin is not a seed: `bin/rails lalabase:setup` creates it.

# Reference data every instance needs: the global chat persona pool (Plan §6.1).
load Rails.root.join('db/seeds/prompt_personas.rb')

# A small demo to click through, for development only. Its accounts have a published
# password, so they must never exist on a server.
load Rails.root.join('db/seeds/demo.rb') if Rails.env.development?

# No price level here since S3.2 of doc/oss_core_split_plan.md: the price
# ladder is the owner's offer, and its seed (Subscriptions::PriceListSeed,
# `BUNDLE_GEMFILE=Gemfile.operator rake subscription_prices:seed`) moved to the
# operator console. Without a published level the public price API
# (/api/public/v1/price_list) answers with an empty payload, and the website,
# which lives in its own repository, shows its "prices unavailable" card. A
# fresh self-hosted instance is in the same state.
