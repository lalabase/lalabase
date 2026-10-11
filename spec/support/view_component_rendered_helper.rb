# frozen_string_literal: true

module ViewComponentRenderedHelper
  # Expose the last rendered component as a Capybara node
  attr_reader :rendered_component

  # Wrap render_inline to capture and expose the returned fragment
  def render_inline(component, &block)
    fragment = super
    # Capybara matchers (have_css, have_content) expect a Capybara::Node::Simple
    @rendered_component = Capybara::Node::Simple.new(fragment.to_html)
    begin
      FileUtils.mkdir_p(Rails.root.join('tmp'))
      info = "component=#{component.class.name} length=#{fragment.to_html.to_s.length}\n"
      File.write(Rails.root.join('tmp/_last_component_debug.txt'), info)
    rescue StandardError
      # ignore debug write errors
    end
    fragment
  end
end

RSpec.configure do |config|
  config.include ViewComponentRenderedHelper, type: :component
end
