require 'spec_helper'
require 'addressable/uri'

describe GoogleAnalyticsFeeds::DataFeed do
  it "builds a URI" do
    request = described_class.new.
      profile(123).
      metrics(:foo, :bar).
      dimensions(:baz).
      dates(Date.new(2010, 3, 14), Date.new(2010, 3, 14)).
      max_results(50).
      start_index(10)

    uri = Addressable::URI.parse(request.uri)
    uri.scheme.should == "https"
    uri.host.should == "www.googleapis.com"
    uri.path.should == "/analytics/v2.4/data"
    uri.query_values.should == {
      "ids" => "ga:123",
      "metrics" => "ga:foo,ga:bar",
      "dimensions" => "ga:baz",
      "start-date" => "2010-03-14",
      "end-date" => "2010-03-14",
      "max-results" => "50",
      "start-index" => "10",
    }
  end

  it "doesn't modify the original request" do
    request = described_class.new.profile(123)
    request.metrics(:foo) # result thrown away

    uri = Addressable::URI.parse(request.uri)
    uri.query_values.should == {"ids" => "ga:123"}
  end

  it "adds the appropriate header and makes the request" do
    connection = mock(:connection)
    headers    = {}
    request    = mock(:request, :headers => headers).as_null_object

    connection.should_receive(:get).and_yield(request)
    described_class.new.retrieve("123", connection)

    headers["Authorization"].should == "GoogleLogin auth=123"
  end

  it "can add filters" do
    feed = described_class.new.
      filters {
      eql :baz, 4
      contains :foo, "123"
    }

    uri = Addressable::URI.parse(feed.uri)
    uri.query_values.should == {
      "filters" => "ga:baz==4;ga:foo=@123"
    }
  end
end
