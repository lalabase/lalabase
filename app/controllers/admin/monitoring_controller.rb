# frozen_string_literal: true

module Admin
  class MonitoringController < ApplicationController
    def index
      @commit_hash = detect_commit_hash
      @last_deployed_at = detect_last_deployed_at
    end

    private

    def detect_commit_hash
      read_revision_file || fetch_git_head
    end

    def detect_last_deployed_at
      path = revision_path
      return nil unless path && File.exist?(path)

      Time.zone ? File.mtime(path).in_time_zone : File.mtime(path)
    rescue StandardError => e
      Rails.logger.warn("Failed to determine last deployment timestamp: #{e.class}: #{e.message}")
      nil
    end

    def revision_path
      Rails.root.join('REVISION')
    rescue StandardError
      nil
    end

    def read_revision_file
      path = revision_path
      return unless path && File.exist?(path)

      File.read(path).strip.presence
    rescue StandardError => e
      Rails.logger.warn("Failed to read revision file: #{e.class}: #{e.message}")
      nil
    end

    def fetch_git_head
      git_dir = Rails.root.join('.git/HEAD')
      return unless File.exist?(git_dir)

      ref = File.read(git_dir).strip
      return ref.presence unless ref.start_with?('ref:')

      ref_path = Rails.root.join(ref.split(' ').last).to_s
      File.read(ref_path).strip.presence if File.exist?(ref_path)
    rescue StandardError => e
      Rails.logger.warn("Failed to read git HEAD: #{e.class}: #{e.message}")
      nil
    end
  end
end
