# frozen_string_literal: true

# Applies normalized participant sets without duplicating meeting rows.
module Meetings
  class ParticipantFilter
    def self.call(scope, values, operator: 'or')
      names = Array(values).map { |value| MeetingParticipant.normalize_name(value.to_s) }.reject(&:blank?).uniq
      return scope.none if names.empty?

      participants = MeetingParticipant.where(normalized_name: names)
      case operator
      when 'and'
        scope.where(id: participants.group(:meeting_id).having('COUNT(DISTINCT normalized_name) = ?', names.size).select(:meeting_id))
      when 'not'
        scope.where.not(id: participants.select(:meeting_id))
      else
        scope.where(id: participants.select(:meeting_id))
      end
    end

    def self.rule_values(value)
      raw = value.to_s.strip
      return [raw] unless raw.start_with?('[')

      parsed = JSON.parse(raw)
      parsed.is_a?(Array) && parsed.all? { |item| item.is_a?(String) && item.present? } ? parsed : []
    rescue JSON::ParserError
      []
    end
  end
end
