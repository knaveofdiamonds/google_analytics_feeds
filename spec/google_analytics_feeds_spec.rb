require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "Parsing property names" do
  it "snake cases, symbolizes and removes ga namespace" do
    GoogleAnalyticsFeeds::DataFeed.new.name_to_symbol("ga:visitorType").should == :visitor_type
  end

  it "converts a ruby symbol to a google analytics name" do
    GoogleAnalyticsFeeds::DataFeed.new.symbol_to_name(:visitor_type).should == "ga:visitorType"
  end
end
