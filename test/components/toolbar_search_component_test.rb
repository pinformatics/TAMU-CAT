require "test_helper"

class ToolbarSearchComponentTest < ActiveSupport::TestCase
  test "stores search configuration for the template" do
    component = ToolbarSearchComponent.new(
      url: "/people_management",
      query: "Jacob",
      param_name: :search,
      placeholder: "Find students",
      hidden_params: { tab: "students", empty: "" }
    )

    assert_equal "/people_management", component.send(:url)
    assert_equal "Jacob", component.send(:query)
    assert_equal :search, component.send(:param_name)
    assert_equal "Find students", component.send(:placeholder)
    assert_equal({ tab: "students", empty: "" }, component.send(:hidden_params))
  end

  test "uses q and generic placeholder by default" do
    component = ToolbarSearchComponent.new(url: "/reports", query: nil)

    assert_equal "/reports", component.send(:url)
    assert_nil component.send(:query)
    assert_equal :q, component.send(:param_name)
    assert_equal "Search...", component.send(:placeholder)
    assert_equal({}, component.send(:hidden_params))
  end
end
