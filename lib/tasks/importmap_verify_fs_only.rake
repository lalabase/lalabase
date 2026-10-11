# frozen_string_literal: true

namespace :importmap do
  desc 'FS-only verify (no Rails boot)'
  task verify_fs_only: :environment do
    sh 'bin/verify-importmap'
  end
end
