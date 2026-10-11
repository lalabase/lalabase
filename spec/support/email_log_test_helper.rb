# frozen_string_literal: true

module EmailLogTestHelper
  def with_tenant(organisation = nil, &block)
    org = organisation || @organisation || create(:organisation)
    ActsAsTenant.with_tenant(org, &block)
  end

  def without_tenant(&block)
    ActsAsTenant.without_tenant(&block)
  end

  def create_email_log_in_tenant(organisation, attrs = {})
    with_tenant(organisation) do
      create(:email_log, attrs.merge(organisation: organisation))
    end
  end

  def find_email_log_in_tenant(organisation, id)
    with_tenant(organisation) do
      EmailLog.find(id)
    end
  end
end

RSpec.configure do |config|
  config.include EmailLogTestHelper, type: :model
  config.include EmailLogTestHelper, type: :request
  config.include EmailLogTestHelper, type: :controller
  config.include EmailLogTestHelper, type: :job
end
