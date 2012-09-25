require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe GoogleAnalyticsFeeds::Session do
  it "raises an AuthenticationError if login is not a success" do
    connection = stub(:connection, :post => stub(:response, :success? => false))
    expect {
      described_class.new(connection).login('name', 'password')
    }.to raise_error(GoogleAnalyticsFeeds::AuthenticationError)
  end

  it "sets and returns a token if login is a success" do
    connection = stub(:connection, :post => stub(:response, :success? => true, :body => "Auth=MYTOKEN"))
    described_class.new(connection).login('name', 'password').should == "MYTOKEN"
  end

  it "posts the username and email to Google Analytics" do
    connection = mock(:connection)
    connection.should_receive(:post).
      with("https://www.google.com/accounts/ClientLogin",
           'Email' => 'me@example.com',
           'Passwd' => 'password',
           'accountType' => 'HOSTED_OR_GOOGLE',
           'service' => 'analytics',
           'source' => 'ruby-google-analytics-feeds').
      and_return(stub(:response, :success? => true, :body => "Auth=MYTOKEN"))

    described_class.new(connection).login('me@example.com', 'password')
  end
end
