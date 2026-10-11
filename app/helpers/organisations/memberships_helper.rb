# frozen_string_literal: true

module Organisations
  module MembershipsHelper
    def membership_role_name(role)
      return t('member_management.no_role') unless role

      t("organisations.memberships.index.role_labels.#{role.title}", default: role.title)
    end

    def membership_list_path(**changes)
      organisation_memberships_path(current_organisation,
                                    **membership_list_params.merge(changes))
    end

    def membership_list_params
      params.slice(:q, :sort, :direction, :membership_id).permit!.to_h.symbolize_keys
    end

    def membership_sort_path(column)
      direction = params[:sort] == column && params[:direction] != 'desc' ? 'desc' : 'asc'
      membership_list_path(sort: column, direction: direction)
    end
  end
end
